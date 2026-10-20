package app

import "core:fmt"
import "core:math"
import "core:slice"
import "om:apple"
import "om:ui"

SHELF_TILE_POINTS :: 150
FIRST_SHELF_TILE_POINTS :: 210
CARD_GAP_POINTS :: 16
// Cards built past each edge of a shelf, so a fast scroll finds them ready.
EXTRA_CARD_COUNT :: 2
ALBUM_COVER_POINTS :: 240

// The tile size that fits a whole number of tiles across width, as close to target as it can.
fit_tile_size :: proc(width, target, gap: f32) -> f32 {
	count := max(1, math.round((width + gap) / (target + gap)))

	return math.floor((width - gap * (count - 1)) / count)
}

// A scrolling page with its title. Children go inside the returned box.
page_scroll :: proc(id: string) -> ^ui.Box {
	box := ui.box(id, {width = ui.fill(), height = ui.fill(), axis = .Y, gap = 24, padding = {PAGE_PADDING_POINTS, 0, PAGE_PADDING_POINTS, PAGE_PADDING_POINTS}, flags = {.Scroll, .Clip}})
	keep_scroll(box)

	return box
}

page_heading :: proc(title: string) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 28, font_weight = .Bold, flags = {.Truncate_Text}}, title)
}

note :: proc(text: string) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, flags = {.Wrap_Text}}, text)
}

build_shelves_page :: proc(title, path: string, is_new: bool) {
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		data.shelves = apple.to_new_shelves(watched.body, page_allocator(data)) if is_new else apple.to_home_shelves(watched.body, page_allocator(data))
	}

	page := page_scroll("shelves")
	run_bench_scroll(page)

	if ui.scope(page) {
		page_heading(title)

		if watched.phase != .Ready {
			note(phase_note(watched.phase))
			return
		}

		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width <= 0 do return

		for shelf, index in data.shelves {
			target: f32 = FIRST_SHELF_TILE_POINTS if index == 0 else SHELF_TILE_POINTS
			build_card_row(fmt.tprintf("shelf %d", index), shelf.title, shelf.cards, fit_tile_size(width, target, CARD_GAP_POINTS))
		}
	}
}

// A shelf of whole tiles, building only those in view. Empty boxes keep the width of the rest.
build_card_row :: proc(id, title: string, cards: []apple.Card, tile_points: f32, is_round := false) {
	if len(cards) == 0 do return

	shelf := ui.box(id, {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10})

	if ui.scope(shelf) {
		if title != "" do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, title)

		row := ui.box("row", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = CARD_GAP_POINTS, flags = {.Scroll, .Clip}})
		step := tile_points + CARD_GAP_POINTS
		first := max(0, int(row.scroll / step) - EXTRA_CARD_COUNT)
		last := min(len(cards) - 1, int((row.scroll + row.size.x) / step) + EXTRA_CARD_COUNT)

		if ui.scope(row) {
			if first > 0 do ui.box("", {width = ui.points(f32(first) * step - CARD_GAP_POINTS), height = ui.points(1)})

			for index in first ..= last {
				if build_card_tile(fmt.tprintf("%d %s", index, cards[index].id), cards[index], tile_points, is_round) do open_card(cards, index)
			}

			if last < len(cards) - 1 do ui.box("", {width = ui.points(f32(len(cards) - 1 - last) * step - CARD_GAP_POINTS), height = ui.points(1)})
		}
	}
}

card_symbols := [apple.Card_Kind]string {
	.Other            = "music.note",
	.Album            = "square.stack",
	.Library_Album    = "square.stack",
	.Artist           = "music.mic",
	.Playlist         = "music.note.list",
	.Library_Playlist = "music.note.list",
	.Song             = "music.note",
}

// Returns true when clicked.
build_card_tile :: proc(id: string, card: apple.Card, tile_points: f32, is_round := false) -> bool {
	can_open := card.kind != .Other
	tile := ui.box(id, {width = ui.points(tile_points), height = ui.fit_children(), axis = .Y, gap = 3, align = .Center if is_round else .Start, flags = {.Clickable} if can_open else {}})

	if ui.scope(tile) {
		radius: f32 = tile_points / 2 if is_round else 8
		art := artwork_box(apple.to_artwork_url(card.artwork, to_artwork_pixels(tile_points)), tile_points, radius, to_placeholder(card.artwork, card.name, card_symbols[card.kind]))

		if ui.scope(art) {
			ui.box("", {width = ui.points(tile_points), height = ui.points(tile_points), corner_radius = radius, background = {1, 1, 1, 0.08 * tile.hot_t}, flags = {.Floating}})
		}

		ui.box("", {width = ui.points(1), height = ui.points(4)})
		text_align := ui.Align.Center if is_round else .Start
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 12.5, text_align = text_align, flags = {.Truncate_Text}}, card.name)
		if !is_round do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, font_size = 12, flags = {.Truncate_Text}}, card.subtitle)
	}

	return ui.signal(tile).is_clicked
}

// A song card plays the shelf's songs from it. The others open their page.
open_card :: proc(cards: []apple.Card, index: int) {
	card := cards[index]

	switch card.kind {
	case .Album, .Library_Album:
		navigate({kind = .Album, id = card.id, title = card.name})
	case .Artist:
		navigate({kind = .Artist, id = card.id, title = card.name})
	case .Playlist:
		navigate({kind = .Catalog_Playlist, id = card.id, title = card.name})
	case .Library_Playlist:
		navigate({kind = .Playlist, id = card.id, title = card.name})
	case .Song:
		songs := make([dynamic]Catalog_Song, context.temp_allocator)
		first := 0
		for other, other_index in cards {
			if other.kind != .Song do continue
			if other_index == index do first = len(songs)
			append(&songs, other.song)
		}
		play_songs(songs[:], first)
	case .Other:
	}
}

// Album IDs from the library start with "l.". Apple gives their catalog album first.
build_album_page :: proc(album_id: string) {
	catalog_id := album_id

	if len(album_id) > 2 && album_id[:2] == "l." {
		link := apple.watch(fmt.tprintf("/v1/me/library/albums/%s/catalog", album_id))
		resources := apple.to_resources(link.body, context.temp_allocator) if link.phase == .Ready else nil

		if len(resources) == 0 {
			page := page_scroll("album")
			if ui.scope(page) do note(phase_note(link.phase) if link.phase != .Ready else "This album is only on the Mac, so Apple Music has no page for it.")
			return
		}
		catalog_id = resources[0].id
	}

	path := fmt.tprintf("/v1/catalog/%s/albums/%s?include=artists&relate=library", apple.STOREFRONT, catalog_id)
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)
	if is_stale && watched.phase == .Ready do read_album(data, watched.body)

	page := page_scroll("album")
	run_bench_scroll(page)

	if ui.scope(page) {
		if watched.phase != .Ready || data.title == "" {
			note(phase_note(watched.phase))
			return
		}

		build_album_header(data)
		build_numbered_songs(data.songs)
	}
}

@(private = "file")
badge_labels := [][2]string{{"hi-res-lossless", "HI-RES LOSSLESS"}, {"lossless", "LOSSLESS"}, {"atmos", "DOLBY ATMOS"}}

read_album :: proc(data: ^Page_Data, body: string) {
	allocator := page_allocator(data)
	resources := apple.to_resources(body, allocator)
	if len(resources) == 0 do return

	album := resources[0]
	attributes := album.attributes
	data.title = attributes.name
	data.subtitle = attributes.artist_name
	data.artwork = attributes.artwork
	artists := apple.list_related(album, "artists")
	if len(artists) > 0 do data.link_id = artists[0].id
	data.is_in_library = len(apple.list_related(album, "library")) > 0

	tracks := apple.list_related(album, "tracks")
	songs := make([]Catalog_Song, len(tracks), allocator)
	for track, index in tracks do songs[index] = apple.to_catalog_song(track)
	data.songs = songs

	genre := attributes.genre_names[0] if len(attributes.genre_names) > 0 else ""
	year := attributes.release_date[:min(4, len(attributes.release_date))]
	data.detail = fmt.aprintf("%s · %s · %d songs", genre, year, len(songs), allocator = allocator)

	badges := make([dynamic]string, allocator)
	for label in badge_labels do if slice.contains(attributes.audio_traits, label[0]) do append(&badges, label[1])
	data.badges = badges[:]
}

build_album_header :: proc(data: ^Page_Data) {
	header := ui.box("header", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 28, padding = {0, 0, 0, 0}})

	if ui.scope(header) {
		artwork_box(apple.to_artwork_url(data.artwork, to_artwork_pixels(ALBUM_COVER_POINTS)), ALBUM_COVER_POINTS, 10, to_placeholder(data.artwork, data.title, "square.stack"))

		info := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 6})

		if ui.scope(info) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 32, font_weight = .Bold, flags = {.Wrap_Text}}, data.title)

			artist := ui.box("artist", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent, font_size = 20, font_weight = .Semibold, flags = {.Clickable} if data.link_id != "" else {}}, data.subtitle)
			if ui.signal(artist).is_clicked do navigate({kind = .Artist, id = data.link_id, title = data.subtitle})

			text_box(data.detail, colors.dim)

			badges := ui.box("badges", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 8, padding = {0, 6, 0, 10}})

			if ui.scope(badges) {
				for label in data.badges do build_badge(label, colors.dim)
				build_badge("In Library" if data.is_in_library else "Not in Library", to_color(0x7ee2a8ff) if data.is_in_library else colors.faint)
			}

			buttons := ui.box("buttons", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 8})

			if ui.scope(buttons) {
				if action_button("Play", "play.fill", true) do play_songs(data.songs, 0)
				if action_button("Shuffle", "shuffle", false) do shuffle_songs(data.songs)
			}
		}
	}
}

build_badge :: proc(label: string, color: [4]f32) {
	ui.box("", {width = ui.fit_text(), height = ui.fit_text(), padding = {6, 1, 6, 1}, corner_radius = 4, border_width = 1, border_color = color, text_color = color, font_size = 11, font_weight = .Bold}, label)
}

// Returns true when clicked. The primary button is filled with the accent.
action_button :: proc(label, symbol: string, is_primary: bool) -> bool {
	background := app.accent if is_primary else colors.field
	hover := background
	hover.a = 0.85 if is_primary else 0.14
	color := to_color(0xffffffff) if is_primary else colors.text
	button := ui.box(label, {width = ui.fit_children(), height = ui.points(32), axis = .X, align = .Center, gap = 6, padding = {14, 0, 16, 0}, corner_radius = 8, background = background, hover_background = hover, flags = {.Clickable}})

	if ui.scope(button) {
		icon_box("", symbol, 12, color)
		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = color, font_weight = .Semibold}, label)
	}

	return ui.signal(button).is_clicked
}

// An album's songs, numbered. A click plays them from that song.
build_numbered_songs :: proc(songs: []Catalog_Song) {
	list := ui.box("songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 1})
	current, is_playing := find_queue_song(app.now_playing.song.persistent_id)

	if ui.scope(list) {
		for song, index in songs {
			is_current := is_playing && current.id == song.id
			tint := to_accent_tint(app.accent)
			row := ui.box(fmt.tprintf("%d %s", index, song.id), {width = ui.fill(), height = ui.points(36), axis = .X, align = .Center, gap = 12, padding = {10, 0, 10, 0}, corner_radius = 7, background = tint if is_current else {}, hover_background = tint if is_current else colors.hover, flags = {.Clickable}})

			if ui.scope(row) {
				ui.box("", {width = ui.points(24), height = ui.fit_text(), text_color = app.accent if is_current else colors.faint}, fmt.tprintf("%d", index + 1))
				text_box(song.name, app.accent if is_current else colors.text)
				ui.box("", {width = ui.points(44), height = ui.fit_text(), text_align = .End, text_color = colors.faint, font_size = 12}, to_clock_text(song.duration_seconds))
			}

			if ui.signal(row).is_clicked do play_songs(songs, index)
		}
	}
}

// Catalog playlists come from shelves. Library ones from the sidebar.
build_playlist_page :: proc(page: Page) {
	is_catalog := page.kind == .Catalog_Playlist
	header_path := fmt.tprintf("/v1/catalog/%s/playlists/%s", apple.STOREFRONT, page.id) if is_catalog else ""
	tracks_path := fmt.tprintf("/v1/catalog/%s/playlists/%s/tracks", apple.STOREFRONT, page.id) if is_catalog else fmt.tprintf("/v1/me/library/playlists/%s/tracks", page.id)
	bodies, signature, phase := watch_all_pages(tracks_path)
	header := apple.watch(header_path) if is_catalog else {phase = .Ready}
	data, is_stale := find_page_data(tracks_path, signature * 7 + header.version, phase)

	if is_stale && phase == .Ready {
		read_library_songs(data, bodies)
		resources := apple.to_resources(header.body, page_allocator(data)) if is_catalog && header.phase == .Ready else nil
		if len(resources) > 0 {
			data.title = resources[0].attributes.name
			data.subtitle = resources[0].attributes.curator_name
		}
	}

	title := data.title if data.title != "" else page.title
	build_song_list_page(title, data.subtitle, data.songs, phase)
}

build_favourite_songs_page :: proc() {
	_, playlist_id, phase := list_playlists()

	if playlist_id == "" {
		build_song_list_page("Favourite Songs", "", nil, phase if phase != .Ready else .Ready)
		return
	}

	build_playlist_page({kind = .Playlist, id = playlist_id, title = "Favourite Songs"})
}
