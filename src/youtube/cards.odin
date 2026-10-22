package youtube

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"

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
	if video_id == "" {
		video_id = as_string(child(value, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"))
	}
	thumbnail := find_thumbnail_url(child(value, "thumbnail"))

	if video_id == "" {
		browse := child(value, "navigationEndpoint", "browseEndpoint")
		subtitle := to_text(child(columns[1], "musicResponsiveListItemFlexColumnRenderer", "text")) if len(columns) > 1 else ""

		return to_browse_card(reader, browse, name, subtitle, thumbnail)
	}

	byline := make([dynamic]json.Value, context.temp_allocator)
	for column in columns[1:] {
		for run in as_array(child(column, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")) {
			append(&byline, run)
		}
	}
	for column in as_array(child(value, "fixedColumns")) {
		for run in as_array(child(column, "musicResponsiveListItemFixedColumnRenderer", "text", "runs")) {
			append(&byline, run)
		}
	}

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
