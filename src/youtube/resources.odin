package youtube

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "om:apple"

// A song from YouTube has this before its video ID, in place of a catalog ID.
SONG_ID_PREFIX :: "yt:"

// What one YouTube answer shows: a page's header, its songs outside shelves, its shelves and its other cards.
List :: struct {
	title:        string,
	subtitle:     string,
	// Such as "757K monthly audience" for an artist.
	detail:       string,
	artwork:      apple.Artwork,
	songs:        []apple.Catalog_Song,
	shelves:      []apple.Shelf,
	cards:        []apple.Card,
	// The token for the next part of a long list. Empty at its end.
	continuation: string,
}

is_song_id :: proc(id: string) -> bool {
	return strings.has_prefix(id, SONG_ID_PREFIX)
}

to_video_id :: proc(song_id: string) -> string {
	return song_id[len(SONG_ID_PREFIX):] if is_song_id(song_id) else ""
}

@(private)
Reader :: struct {
	allocator:    mem.Allocator,
	title:        string,
	subtitle:     string,
	detail:       string,
	artwork:      apple.Artwork,
	songs:        [dynamic]apple.Catalog_Song,
	shelves:      [dynamic]apple.Shelf,
	cards:        [dynamic]apple.Card,
	continuation: string,
}

// Reads any answer of browse, search or next. The JSON is read in the temp allocator, and what is kept is copied into allocator.
to_list :: proc(body: string, allocator := context.allocator) -> List {
	value, error := json.parse_string(body, allocator = context.temp_allocator)
	if error != nil do return {}

	reader := Reader {
		allocator = allocator,
		songs     = make([dynamic]apple.Catalog_Song, allocator),
		shelves   = make([dynamic]apple.Shelf, allocator),
		cards     = make([dynamic]apple.Card, allocator),
	}
	read_value(&reader, value)

	// An album's rows name neither its artist nor its cover, which its header holds.
	for &song in reader.songs {
		if song.artwork.url != "" do continue

		song.artwork = reader.artwork
		if song.artist_name == "" do song.artist_name = reader.subtitle
		if song.album_name == "" do song.album_name = reader.title
	}

	return {reader.title, reader.subtitle, reader.detail, reader.artwork, reader.songs[:], reader.shelves[:], reader.cards[:], reader.continuation}
}

@(private)
read_value :: proc(reader: ^Reader, value: json.Value) {
	#partial switch item in value {
	case json.Array:
		for element in item do read_value(reader, element)
	case json.Object:
		for key, child_value in item {
			switch key {
			case "musicCarouselShelfRenderer":
				read_shelf(reader, child_value)
			case "musicResponsiveListItemRenderer", "playlistPanelVideoRenderer", "musicTwoRowItemRenderer":
				read_item(reader, key, child_value)
			case "musicResponsiveHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer":
				read_header(reader, child_value)
			case "continuationCommand":
				if reader.continuation == "" do reader.continuation = clone(reader, as_string(child(child_value, "token")))
			case "nextContinuationData":
				if reader.continuation == "" do reader.continuation = clone(reader, as_string(child(child_value, "continuation")))
			case:
				read_value(reader, child_value)
			}
		}
	}
}

@(private)
read_item :: proc(reader: ^Reader, key: string, value: json.Value) {
	card, ok := to_card(reader, key, value)
	if !ok do return

	if card.kind == .Song && key != "musicTwoRowItemRenderer" {
		append(&reader.songs, card.song)
		return
	}
	append(&reader.cards, card)
}

@(private)
read_shelf :: proc(reader: ^Reader, value: json.Value) {
	title := to_text(child(value, "header", "musicCarouselShelfBasicHeaderRenderer", "title"))
	cards := make([dynamic]apple.Card, reader.allocator)
	is_wide := false

	for item in as_array(child(value, "contents")) {
		object, is_object := item.(json.Object)
		if !is_object do continue

		for key, item_value in object {
			card, ok := to_card(reader, key, item_value)
			if !ok do continue

			append(&cards, card)
			if len(cards) == 1 do is_wide = is_wide_thumbnail(item_value)
		}
	}

	if len(cards) > 0 do append(&reader.shelves, apple.Shelf{title = clone(reader, title), cards = cards[:], is_youtube = true, is_wide = is_wide})
}

@(private)
read_header :: proc(reader: ^Reader, value: json.Value) {
	if reader.title != "" do return

	reader.title = clone(reader, to_text(child(value, "title")))
	strapline := to_text(child(value, "straplineTextOne"))
	reader.subtitle = clone(reader, strapline if strapline != "" else to_text(child(value, "subtitle")))
	detail := to_text(child(value, "monthlyListenerCount"))
	reader.detail = clone(reader, detail if detail != "" else to_text(child(value, "secondSubtitle")))
	thumbnail := child(value, "thumbnail")
	if thumbnail == nil do thumbnail = child(value, "foregroundThumbnail")
	reader.artwork = to_artwork(reader, find_thumbnail_url(thumbnail), "")
}

// A song, a video, an album, a playlist, a mix or an artist. A podcast or an episode is none of these.
@(private)
to_card :: proc(reader: ^Reader, key: string, value: json.Value) -> (apple.Card, bool) {
	switch key {
	case "playlistPanelVideoRenderer":
		return to_panel_song(reader, value)
	case "musicResponsiveListItemRenderer":
		return to_list_item(reader, value)
	case "musicTwoRowItemRenderer":
		return to_tile(reader, value)
	}

	return {}, false
}

// A row of a playlist, an album, a search or a shelf of songs.
@(private)
to_list_item :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	columns := as_array(child(value, "flexColumns"))
	if len(columns) == 0 do return {}, false

	name := to_text(child(columns[0], "musicResponsiveListItemFlexColumnRenderer", "text"))
	video_id := as_string(child(value, "playlistItemData", "videoId"))
	if video_id == "" do video_id = as_string(child(value, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"))
	thumbnail := find_thumbnail_url(child(value, "thumbnail"))

	if video_id == "" {
		browse := child(value, "navigationEndpoint", "browseEndpoint")
		subtitle := to_text(child(columns[1], "musicResponsiveListItemFlexColumnRenderer", "text")) if len(columns) > 1 else ""

		return to_browse_card(reader, browse, name, subtitle, thumbnail)
	}

	byline := make([dynamic]json.Value, context.temp_allocator)
	for column in columns[1:] do for run in as_array(child(column, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")) do append(&byline, run)
	for column in as_array(child(value, "fixedColumns")) do for run in as_array(child(column, "musicResponsiveListItemFixedColumnRenderer", "text", "runs")) do append(&byline, run)

	return to_song_card(reader, video_id, name, byline[:], thumbnail), true
}

// A song of a radio or a mix, from the next endpoint.
@(private)
to_panel_song :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	video_id := as_string(child(value, "videoId"))
	if video_id == "" do return {}, false

	byline := make([dynamic]json.Value, context.temp_allocator)
	for run in as_array(child(value, "longBylineText", "runs")) do append(&byline, run)
	for run in as_array(child(value, "lengthText", "runs")) do append(&byline, run)

	return to_song_card(reader, video_id, to_text(child(value, "title")), byline[:], find_thumbnail_url(child(value, "thumbnail"))), true
}

// A tile on a shelf. A video plays, the rest open their page.
@(private)
to_tile :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	name := to_text(child(value, "title"))
	thumbnail := find_thumbnail_url(child(value, "thumbnailRenderer"))
	endpoint := child(value, "navigationEndpoint")

	if video_id := as_string(child(endpoint, "watchEndpoint", "videoId")); video_id != "" {
		return to_song_card(reader, video_id, name, as_array(child(value, "subtitle", "runs"))[:], thumbnail), true
	}

	subtitle := to_text(child(value, "subtitle"))

	if playlist_id := as_string(child(endpoint, "watchPlaylistEndpoint", "playlistId")); playlist_id != "" {
		return apple.Card{id = clone(reader, playlist_id), kind = .YouTube_Playlist, name = clone(reader, name), subtitle = clone(reader, subtitle), artwork = to_artwork(reader, thumbnail, "")}, true
	}

	return to_browse_card(reader, child(endpoint, "browseEndpoint"), name, subtitle, thumbnail)
}

@(private)
to_browse_card :: proc(reader: ^Reader, browse: json.Value, name, subtitle, thumbnail: string) -> (apple.Card, bool) {
	browse_id := as_string(child(browse, "browseId"))
	page_type := as_string(child(browse, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"))
	kind: apple.Card_Kind

	switch page_type {
	case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_PLAYLIST", "MUSIC_PAGE_TYPE_AUDIOBOOK":
		kind = .YouTube_Playlist
	case "MUSIC_PAGE_TYPE_ARTIST":
		kind = .YouTube_Artist
	case:
		return {}, false
	}

	return apple.Card{id = clone(reader, browse_id), kind = kind, name = clone(reader, name), subtitle = clone(reader, subtitle), artwork = to_artwork(reader, thumbnail, "")}, true
}

// The byline names the artists and the album with links to them, and holds the length as "4:23".
@(private)
to_song_card :: proc(reader: ^Reader, video_id, name: string, byline: []json.Value, thumbnail: string) -> apple.Card {
	artists := make([dynamic]string, context.temp_allocator)
	album := ""
	duration_seconds: f64
	first_text := ""

	for run in byline {
		text := as_string(child(run, "text"))
		browse_id := as_string(child(run, "navigationEndpoint", "browseEndpoint", "browseId"))

		switch {
		case strings.has_prefix(browse_id, "MPREb_"):
			album = text
		case strings.has_prefix(browse_id, "UC"):
			append(&artists, text)
		case to_seconds(text) > 0:
			duration_seconds = to_seconds(text)
		case first_text == "" && !is_label(text):
			first_text = text
		}
	}

	if len(artists) == 0 && first_text != "" do append(&artists, first_text)

	song := apple.Catalog_Song {
		id               = fmt.aprintf("%s%s", SONG_ID_PREFIX, video_id, allocator = reader.allocator),
		name             = clone(reader, name),
		artist_name      = strings.join(artists[:], ", ", reader.allocator),
		album_name       = clone(reader, album),
		duration_seconds = duration_seconds,
		artwork          = to_artwork(reader, thumbnail, video_id),
	}

	return {id = song.id, kind = .Song, name = song.name, subtitle = song.artist_name, artwork = song.artwork, song = song}
}

// The words YouTube puts between a song's details, such as "Song" or "16M plays".
@(private)
is_label :: proc(text: string) -> bool {
	labels := []string{" • ", "Song", "Video", "Single", "EP", "Album", "Episode", "Playlist"}
	for label in labels do if text == label do return true

	return strings.has_suffix(text, " plays") || strings.has_suffix(text, " views")
}

// "4:23" or "1:02:03" in seconds. 0 for any other text.
@(private)
to_seconds :: proc(text: string) -> f64 {
	if len(text) < 4 || len(text) > 8 do return 0

	seconds: f64
	for part in strings.split(text, ":", context.temp_allocator) {
		if len(part) == 0 do return 0
		value := 0
		for character in part {
			if character < '0' || character > '9' do return 0
			value = value * 10 + int(character - '0')
		}
		seconds = seconds * 60 + f64(value)
	}

	return seconds if strings.contains_rune(text, ':') else 0
}

// A Google photo URL ends in its size, as "=w120-h120-l90-rj" or "=s576", which becomes {w} and {h} as in Apple's.
// A video's thumbnail is its plain hqdefault.jpg, which shows it in 16:9 between black bars, cropped away.
@(private)
to_artwork :: proc(reader: ^Reader, url, video_id: string) -> apple.Artwork {
	if strings.contains(url, "i.ytimg.com/vi/") && video_id != "" {
		return {url = fmt.aprintf("https://i.ytimg.com/vi/%s/hqdefault.jpg", video_id, allocator = reader.allocator)}
	}

	if square_start := strings.last_index(url, "=s"); square_start >= 0 && strings.index_any(url[square_start + 2:], "-=") < 0 {
		return {url = fmt.aprintf("%s=w{{w}}-h{{h}}", url[:square_start], allocator = reader.allocator)}
	}

	size_start := strings.last_index(url, "=w")
	if size_start < 0 do return {url = clone(reader, url)}

	rest := url[size_start + 2:]
	dash := strings.index(rest, "-h")
	if dash < 0 do return {url = clone(reader, url)}

	height_end := dash + 2
	for height_end < len(rest) && rest[height_end] >= '0' && rest[height_end] <= '9' do height_end += 1

	return {url = fmt.aprintf("%s=w{{w}}-h{{h}}%s", url[:size_start], rest[height_end:], allocator = reader.allocator)}
}

@(private)
is_wide_thumbnail :: proc(value: json.Value) -> bool {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return false

	last := thumbnails[len(thumbnails) - 1]
	width := as_number(child(last, "width"))
	height := as_number(child(last, "height"))

	return height > 0 && width > height * 1.3
}

// The largest thumbnail's URL, wherever under value its list is.
@(private)
find_thumbnail_url :: proc(value: json.Value) -> string {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return ""

	return as_string(child(thumbnails[len(thumbnails) - 1], "url"))
}

@(private)
find_thumbnails :: proc(value: json.Value) -> json.Array {
	object, ok := value.(json.Object)
	if !ok do return nil

	for key, child_value in object {
		if key == "thumbnails" do return as_array(child_value)
		if found := find_thumbnails(child_value); len(found) > 0 do return found
	}

	return nil
}

// ---- Reading JSON values ----

@(private)
child :: proc(value: json.Value, keys: ..string) -> json.Value {
	current := value

	for key in keys {
		object, ok := current.(json.Object)
		if !ok do return nil
		current = object[key] or_else nil
	}

	return current
}

@(private)
as_string :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)

	return text
}

@(private)
as_array :: proc(value: json.Value) -> json.Array {
	array, _ := value.(json.Array)

	return array
}

@(private)
as_number :: proc(value: json.Value) -> f64 {
	#partial switch number in value {
	case json.Float:
		return f64(number)
	case json.Integer:
		return f64(number)
	}

	return 0
}

// The text of a "runs" list, joined, or of a "simpleText".
@(private)
to_text :: proc(value: json.Value) -> string {
	if simple := as_string(child(value, "simpleText")); simple != "" do return simple

	builder := strings.builder_make(context.temp_allocator)
	for run in as_array(child(value, "runs")) do strings.write_string(&builder, as_string(child(run, "text")))

	return strings.to_string(builder)
}

@(private)
clone :: proc(reader: ^Reader, text: string) -> string {
	return strings.clone(text, reader.allocator)
}
