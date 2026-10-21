package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode"
import "om:apple"
import "om:ui"

ARTIST_HEADER_POINTS :: 300
// The photo width steps up by this much, so a resize reuses a photo Apple already sent.
PHOTO_WIDTH_STEP_PIXELS :: 400
ARTIST_ALBUM_POINTS :: 150
LATEST_RELEASE_POINTS :: 210
SIMILAR_ARTIST_POINTS :: 130

// Music.app gives a song's artist only as a name. The catalog artist with that exact name is the one.
find_artist_id :: proc(artist_name: string) -> (string, apple.Phase) {
	watched := apple.watch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=artists&limit=12", apple.STOREFRONT, to_query_text(artist_name)))
	if watched.phase != .Ready do return "", watched.phase

	Search_Answer :: struct {
		results: struct {
			artists: apple.Related,
		},
	}
	answer: Search_Answer
	_ = unmarshal_text(watched.body, &answer)
	artists := answer.results.artists.data
	if len(artists) == 0 do return "", .Failed

	for artist in artists do if artist.attributes.name == artist_name do return artist.id, .Ready

	return artists[0].id, .Ready
}

// An artist page opened by name, from the player bar, finds its ID first.
build_artist_page :: proc(page_id: string, name: string) {
	artist_id := page_id

	if artist_id == "" {
		found, phase := find_artist_id(name)

		if found == "" {
			page := page_scroll("artist")
			if ui.scope(page) do note(phase_note(phase) if phase != .Ready else fmt.tprintf("Apple Music has no artist named %s.", name))
			return
		}
		artist_id = found
	}

	views := "top-songs,latest-release,full-albums,similar-artists"
	path := fmt.tprintf("/v1/catalog/%s/artists/%s?views=%s", apple.STOREFRONT, artist_id, views)
	watched := apple.watch(path)
	catalog_name := ""

	if watched.phase == .Ready {
		resources := apple.to_resources(watched.body, context.temp_allocator)
		if len(resources) > 0 do catalog_name = resources[0].attributes.name
	}

	library_albums := watch_library_albums_of(catalog_name)
	data, is_stale := find_page_data(path, watched.version * 31 + library_albums.version, watched.phase)
	if is_stale && watched.phase == .Ready do read_artist(data, watched.body, library_albums)

	page := page_scroll("artist")
	run_bench_scroll(page)

	if ui.scope(page) {
		if watched.phase != .Ready || data.title == "" {
			note(phase_note(watched.phase))
			return
		}

		width := page.size.x - page.style.padding.x - page.style.padding.z
		build_artist_header(data, width)
		build_artist_middle(data)

		if width > 0 {
			build_card_row("library", "In Your Library", data.library_cards, fit_tile_size(width, ARTIST_ALBUM_POINTS, CARD_GAP_POINTS))
			build_card_row("albums", "Albums", data.cards, fit_tile_size(width, ARTIST_ALBUM_POINTS, CARD_GAP_POINTS))
			build_recent_songs_shelf(artist_id, data.title)
			build_card_row("similar", "Similar Artists", data.similar, fit_tile_size(width, SIMILAR_ARTIST_POINTS, CARD_GAP_POINTS), true)
		}
	}
}

// Library search misses a term with an apostrophe, so it searches the longest word and checks the full name.
@(private = "file")
watch_library_albums_of :: proc(artist_name: string) -> apple.Watched {
	if artist_name == "" do return {phase = .Loading}

	longest := ""
	word_start := -1
	for character, index in artist_name {
		is_letter := unicode.is_letter(character) || unicode.is_digit(character)
		if is_letter && word_start < 0 do word_start = index
		if !is_letter && word_start >= 0 {
			if index - word_start > len(longest) do longest = artist_name[word_start:index]
			word_start = -1
		}
	}
	if word_start >= 0 && len(artist_name) - word_start > len(longest) do longest = artist_name[word_start:]

	search := apple.watch(fmt.tprintf("/v1/me/library/search?term=%s&types=library-artists&limit=25", to_query_text(longest)))
	if search.phase != .Ready do return {phase = search.phase, version = search.version}

	Search_Answer :: struct {
		results: struct {
			library_artists: struct {
				data: []apple.Resource,
			} `json:"library-artists"`,
		},
	}
	answer: Search_Answer
	_ = unmarshal_text(search.body, &answer)

	for artist in answer.results.library_artists.data {
		if artist.attributes.name != artist_name do continue

		albums := apple.watch(fmt.tprintf("/v1/me/library/artists/%s/albums", artist.id))
		albums.version += search.version * 1000

		return albums
	}

	return {phase = .Ready, version = search.version * 1000}
}

@(private = "file")
read_artist :: proc(data: ^Page_Data, body: string, library_albums: apple.Watched) {
	allocator := page_allocator(data)
	resources := apple.to_resources(body, allocator)
	if len(resources) == 0 do return

	artist := resources[0]
	attributes := artist.attributes
	data.title = attributes.name
	data.detail = attributes.genre_names[0] if len(attributes.genre_names) > 0 else ""
	data.artwork = attributes.artwork

	top_songs := apple.list_view(artist, "top-songs")
	songs := make([]Catalog_Song, len(top_songs), allocator)
	for song, index in top_songs do songs[index] = apple.to_catalog_song(song)
	data.songs = songs

	data.latest = apple.list_cards(apple.list_view(artist, "latest-release"), allocator)
	data.cards = apple.list_cards(apple.list_view(artist, "full-albums"), allocator)
	data.similar = apple.list_cards(apple.list_view(artist, "similar-artists"), allocator)

	if library_albums.phase == .Ready && library_albums.body != "" {
		data.library_cards = apple.list_cards(apple.to_resources(library_albums.body, allocator), allocator)
	}
}

@(private = "file")
build_artist_header :: proc(data: ^Page_Data, width: f32) {
	fallback := to_color_from_hex(fmt.tprintf("#%s", data.artwork.bg_color)) if len(data.artwork.bg_color) == 6 else colors.card
	header := ui.box("header", {width = ui.fill(), height = ui.points(ARTIST_HEADER_POINTS)})

	if ui.scope(header) {
		if width > 0 {
			photo_width := int(math.ceil(ui.to_pixels(width) / PHOTO_WIDTH_STEP_PIXELS)) * PHOTO_WIDTH_STEP_PIXELS
			photo_height := int(ui.to_pixels(ARTIST_HEADER_POINTS))
			photo := apple.to_artwork_url(data.artwork, photo_width, photo_height)
			box := artwork_rect_box(photo, {width, ARTIST_HEADER_POINTS}, 12, {top = fallback, bottom = fallback})
			box.style.flags += {.Floating}
		}

		ink := colors.window
		ui.box("", {
			width          = ui.fill(),
			height         = ui.fill(),
			corner_radius  = 12,
			background     = {ink.r, ink.g, ink.b, 0},
			end_background = {ink.r, ink.g, ink.b, 0xf2 / 255.0},
			gradient       = {0.35, 1},
			flags          = {.Floating},
		})

		bottom := ui.box("bottom", {width = ui.fill(), height = ui.fill(), axis = .X, align = .End, gap = 10, padding = {20, 0, 20, 18}, flags = {.Floating}})

		if ui.scope(bottom) {
			name := ui.box("name", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(name) {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 40, font_weight = .Bold, flags = {.Truncate_Text}}, data.title)
				text_box(data.detail, to_color(0xcfcfd4ff), 14)
			}

			if action_button("Play", "play.fill", true) do play_songs(data.songs, 0)
			if action_button("Shuffle", "shuffle", false) do shuffle_songs(data.songs)
		}
	}
}

@(private = "file")
build_artist_middle :: proc(data: ^Page_Data) {
	middle := ui.box("middle", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 20})

	if ui.scope(middle) {
		if len(data.latest) > 0 {
			latest := ui.box("latest", {width = ui.points(LATEST_RELEASE_POINTS), height = ui.fit_children(), axis = .Y, gap = 10})

			if ui.scope(latest) {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, "Latest Release")
				if build_card_tile("latest card", data.latest[0], LATEST_RELEASE_POINTS) do open_card(data.latest, 0)
			}
		}

		top := ui.box("top songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10})

		if ui.scope(top) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, "Top Songs")

			build_song_grid(data.songs, nil, data.songs)
		}
	}
}

to_query_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	for byte_value in transmute([]u8)text {
		is_plain := (byte_value >= 'a' && byte_value <= 'z') || (byte_value >= 'A' && byte_value <= 'Z') || (byte_value >= '0' && byte_value <= '9') || byte_value == '-' || byte_value == '.' || byte_value == '_'

		if is_plain {
			strings.write_byte(&builder, byte_value)
		} else {
			fmt.sbprintf(&builder, "%%%02X", byte_value)
		}
	}

	return strings.to_string(builder)
}
