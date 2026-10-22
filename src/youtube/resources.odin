package youtube

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "om:apple"

// A song from YouTube has this before its video ID, in place of a catalog ID.
SONG_ID_PREFIX :: "yt:"

// What one YouTube answer shows: a page's header, its songs outside shelves,
// its shelves and its other cards.
List :: struct {
	title:                string,
	subtitle:             string,
	// Such as "757K monthly audience" for an artist.
	detail:               string,
	artwork:              apple.Artwork,
	songs:                []apple.Catalog_Song,
	shelves:              []apple.Shelf,
	cards:                []apple.Card,
	// The token for the next part of a long list. Empty at its end.
	continuation:         string,
	// The token for the next shelves of a page, such as home. to_continuation_path cannot use it.
	section_continuation: string,
}

is_song_id :: proc(id: string) -> bool {
	return strings.has_prefix(id, SONG_ID_PREFIX)
}

to_video_id :: proc(song_id: string) -> string {
	return song_id[len(SONG_ID_PREFIX):] if is_song_id(song_id) else ""
}

@(private)
Reader :: struct {
	allocator:            mem.Allocator,
	title:                string,
	subtitle:             string,
	detail:               string,
	artwork:              apple.Artwork,
	songs:                [dynamic]apple.Catalog_Song,
	shelves:              [dynamic]apple.Shelf,
	cards:                [dynamic]apple.Card,
	continuation:         string,
	section_continuation: string,
}

// Reads any answer of browse, search or next. It copies what it keeps into allocator.
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

	return {
		reader.title,
		reader.subtitle,
		reader.detail,
		reader.artwork,
		reader.songs[:],
		reader.shelves[:],
		reader.cards[:],
		reader.continuation,
		reader.section_continuation,
	}
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
			case "musicResponsiveListItemRenderer",
			     "playlistPanelVideoRenderer",
			     "musicTwoRowItemRenderer":
				read_item(reader, key, child_value)
			case "musicResponsiveHeaderRenderer",
			     "musicImmersiveHeaderRenderer",
			     "musicVisualHeaderRenderer",
			     "musicDetailHeaderRenderer",
			     "musicEditablePlaylistDetailHeaderRenderer":
				read_header(reader, child_value)
			case "continuationCommand":
				if reader.continuation == "" {
					reader.continuation = clone(reader, as_string(child(child_value, "token")))
				}
			case "nextContinuationData":
				if reader.section_continuation == "" {
					reader.section_continuation = clone(
						reader,
						as_string(child(child_value, "continuation")),
					)
				}
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

	if len(cards) == 0 do return

	append(
		&reader.shelves,
		apple.Shelf {
			title = clone(reader, title),
			cards = cards[:],
			is_youtube = true,
			is_wide = is_wide,
		},
	)
}

@(private)
read_header :: proc(reader: ^Reader, value: json.Value) {
	if reader.title != "" do return

	reader.title = clone(reader, to_text(child(value, "title")))

	strapline := to_text(child(value, "straplineTextOne"))
	reader.subtitle = clone(
		reader,
		strapline if strapline != "" else to_text(child(value, "subtitle")),
	)

	detail := to_text(child(value, "monthlyListenerCount"))
	reader.detail = clone(
		reader,
		detail if detail != "" else to_text(child(value, "secondSubtitle")),
	)

	thumbnail := child(value, "thumbnail")
	if thumbnail == nil do thumbnail = child(value, "foregroundThumbnail")
	reader.artwork = to_artwork(reader, find_thumbnail_url(thumbnail), "")
}
