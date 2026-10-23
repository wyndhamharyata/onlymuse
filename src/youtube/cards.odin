package youtube

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"

@(private)
TILE_RENDERER :: "musicTwoRowItemRenderer"
@(private)
FLEX_COLUMN_RENDERER :: "musicResponsiveListItemFlexColumnRenderer"

@(private)
to_card :: proc(reader: ^Reader, key: string, value: json.Value) -> (apple.Card, bool) {
	switch key {
	case "playlistPanelVideoRenderer":
		return to_panel_song(reader, value)
	case "musicResponsiveListItemRenderer":
		return to_list_item(reader, value)
	case TILE_RENDERER:
		return to_tile(reader, value)
	}

	return {}, false
}

@(private)
to_list_item :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	columns := to_array(find_child(value, "flexColumns"))
	if len(columns) == 0 do return {}, false

	name := to_text(find_child(columns[0], FLEX_COLUMN_RENDERER, "text"))
	video_id := to_string(find_child(value, "playlistItemData", "videoId"))

	if video_id == "" {
		video_id = to_string(
			find_child(
				value,
				"overlay",
				"musicItemThumbnailOverlayRenderer",
				"content",
				"musicPlayButtonRenderer",
				"playNavigationEndpoint",
				"watchEndpoint",
				"videoId",
			),
		)
	}

	thumbnail := find_thumbnail_url(find_child(value, "thumbnail"))

	if video_id == "" {
		browse := find_child(value, "navigationEndpoint", "browseEndpoint")
		subtitle :=
			to_text(find_child(columns[1], FLEX_COLUMN_RENDERER, "text")) if len(columns) > 1 else ""

		return to_browse_card(reader, browse, name, subtitle, thumbnail)
	}

	byline := make([dynamic]json.Value, context.temp_allocator)

	for column in columns[1:] {
		for run in to_array(find_child(column, FLEX_COLUMN_RENDERER, "text", "runs")) {
			append(&byline, run)
		}
	}

	for column in to_array(find_child(value, "fixedColumns")) {
		for run in to_array(
			find_child(column, "musicResponsiveListItemFixedColumnRenderer", "text", "runs"),
		) {
			append(&byline, run)
		}
	}

	return to_song_card(reader, video_id, name, byline[:], thumbnail), true
}

@(private)
to_panel_song :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	video_id := to_string(find_child(value, "videoId"))
	if video_id == "" do return {}, false

	byline := make([dynamic]json.Value, context.temp_allocator)
	for run in to_array(find_child(value, "longBylineText", "runs")) do append(&byline, run)
	for run in to_array(find_child(value, "lengthText", "runs")) do append(&byline, run)

	return to_song_card(
			reader,
			video_id,
			to_text(find_child(value, "title")),
			byline[:],
			find_thumbnail_url(find_child(value, "thumbnail")),
		),
		true
}

@(private)
to_tile :: proc(reader: ^Reader, value: json.Value) -> (apple.Card, bool) {
	name := to_text(find_child(value, "title"))
	thumbnail := find_thumbnail_url(find_child(value, "thumbnailRenderer"))
	endpoint := find_child(value, "navigationEndpoint")

	if video_id := to_string(find_child(endpoint, "watchEndpoint", "videoId")); video_id != "" {
		return to_song_card(
				reader,
				video_id,
				name,
				to_array(find_child(value, "subtitle", "runs"))[:],
				thumbnail,
			),
			true
	}

	subtitle := to_text(find_child(value, "subtitle"))

	if playlist_id := to_string(find_child(endpoint, "watchPlaylistEndpoint", "playlistId"));
	   playlist_id != "" {
		return apple.Card {
				id = make_copy(reader, playlist_id),
				kind = .YouTube_Playlist,
				name = make_copy(reader, name),
				subtitle = make_copy(reader, subtitle),
				artwork = to_artwork(reader, thumbnail, ""),
			},
			true
	}

	return to_browse_card(
		reader,
		find_child(endpoint, "browseEndpoint"),
		name,
		subtitle,
		thumbnail,
	)
}

@(private)
to_browse_card :: proc(
	reader: ^Reader,
	browse: json.Value,
	name, subtitle, thumbnail: string,
) -> (
	apple.Card,
	bool,
) {
	browse_id := to_string(find_child(browse, "browseId"))
	page_type := to_string(
		find_child(
			browse,
			"browseEndpointContextSupportedConfigs",
			"browseEndpointContextMusicConfig",
			"pageType",
		),
	)
	kind: apple.Card_Kind

	switch page_type {
	case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_PLAYLIST", "MUSIC_PAGE_TYPE_AUDIOBOOK":
		kind = .YouTube_Playlist
	case "MUSIC_PAGE_TYPE_ARTIST":
		kind = .YouTube_Artist
	case:
		return {}, false
	}

	return apple.Card {
			id = make_copy(reader, browse_id),
			kind = kind,
			name = make_copy(reader, name),
			subtitle = make_copy(reader, subtitle),
			artwork = to_artwork(reader, thumbnail, ""),
		},
		true
}

@(private)
to_song_card :: proc(
	reader: ^Reader,
	video_id, name: string,
	byline: []json.Value,
	thumbnail: string,
) -> apple.Card {
	artists := make([dynamic]string, context.temp_allocator)
	album := ""
	duration_seconds: f64
	first_text := ""

	for run in byline {
		text := to_string(find_child(run, "text"))
		browse_id := to_string(find_child(run, "navigationEndpoint", "browseEndpoint", "browseId"))
		seconds := to_seconds(text)

		switch {
		case strings.has_prefix(browse_id, "MPREb_"):
			album = text
		case strings.has_prefix(browse_id, "UC"):
			append(&artists, text)
		case seconds > 0:
			duration_seconds = seconds
		case first_text == "" && !is_label(text):
			first_text = text
		}
	}

	if len(artists) == 0 && first_text != "" do append(&artists, first_text)

	song := apple.Catalog_Song {
		id               = fmt.aprintf(
			"%s%s",
			SONG_ID_PREFIX,
			video_id,
			allocator = reader.allocator,
		),
		name             = make_copy(reader, name),
		artist_name      = strings.join(artists[:], ", ", reader.allocator),
		album_name       = make_copy(reader, album),
		duration_seconds = duration_seconds,
		artwork          = to_artwork(reader, thumbnail, video_id),
	}

	return {
		id = song.id,
		kind = .Song,
		name = song.name,
		subtitle = song.artist_name,
		artwork = song.artwork,
		song = song,
	}
}

@(private)
is_label :: proc(text: string) -> bool {
	labels := []string{" • ", "Song", "Video", "Single", "EP", "Album", "Episode", "Playlist"}
	for label in labels do if text == label do return true

	return strings.has_suffix(text, " plays") || strings.has_suffix(text, " views")
}

@(private)
to_seconds :: proc(text: string) -> f64 {
	if !strings.contains_rune(text, ':') do return 0
	if len(text) < len("0:00") || len(text) > len("00:00:00") do return 0

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

	return seconds
}
