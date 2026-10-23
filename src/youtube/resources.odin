package youtube

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "om:apple"

SONG_ID_PREFIX :: "yt:"

List :: struct {
	title:                string,
	subtitle:             string,
	detail:               string,
	artwork:              apple.Artwork,
	songs:                []apple.Catalog_Song,
	shelves:              []apple.Shelf,
	cards:                []apple.Card,
	continuation:         string,
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
			case "musicResponsiveListItemRenderer", "playlistPanelVideoRenderer", TILE_RENDERER:
				read_item(reader, key, child_value)
			case "musicResponsiveHeaderRenderer",
			     "musicImmersiveHeaderRenderer",
			     "musicVisualHeaderRenderer",
			     "musicDetailHeaderRenderer",
			     "musicEditablePlaylistDetailHeaderRenderer":
				read_header(reader, child_value)
			case "continuationCommand":
				if reader.continuation == "" {
					reader.continuation = make_copy(
						reader,
						to_string(find_child(child_value, "token")),
					)
				}
			case "nextContinuationData":
				if reader.section_continuation == "" {
					reader.section_continuation = make_copy(
						reader,
						to_string(find_child(child_value, "continuation")),
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

	is_list_song := card.kind == .Song && key != TILE_RENDERER

	if is_list_song {
		append(&reader.songs, card.song)
		return
	}

	append(&reader.cards, card)
}

@(private)
read_shelf :: proc(reader: ^Reader, value: json.Value) {
	title := to_text(find_child(value, "header", "musicCarouselShelfBasicHeaderRenderer", "title"))
	cards := make([dynamic]apple.Card, reader.allocator)
	is_wide := false

	for item in to_array(find_child(value, "contents")) {
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
			title = make_copy(reader, title),
			cards = cards[:],
			is_youtube = true,
			is_wide = is_wide,
		},
	)
}

@(private)
read_header :: proc(reader: ^Reader, value: json.Value) {
	if reader.title != "" do return

	reader.title = make_copy(reader, to_text(find_child(value, "title")))

	strapline := to_text(find_child(value, "straplineTextOne"))
	reader.subtitle = make_copy(
		reader,
		strapline if strapline != "" else to_text(find_child(value, "subtitle")),
	)

	detail := to_text(find_child(value, "monthlyListenerCount"))
	reader.detail = make_copy(
		reader,
		detail if detail != "" else to_text(find_child(value, "secondSubtitle")),
	)

	thumbnail := find_child(value, "thumbnail")
	if thumbnail == nil do thumbnail = find_child(value, "foregroundThumbnail")
	reader.artwork = to_artwork(reader, find_thumbnail_url(thumbnail), "")
}
