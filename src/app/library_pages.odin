package app

import "core:fmt"
import "om:apple"
import "om:ui"

SONG_ROW_POINTS :: 54
SONG_ARTWORK_POINTS :: 40
// The tile size that fits a whole number of tiles across, as close to this as it can.
TARGET_TILE_POINTS :: 160
TILE_GAP_POINTS :: 14
// The title and the artist under a tile.
TILE_TEXT_POINTS :: 46
// Artwork is asked for in steps of this many pixels, so a resized window reuses the saved files.
ARTWORK_STEP_PIXELS :: 100
// Rows built past each edge of a list, so a fast scroll finds them ready.
EXTRA_ROW_COUNT :: 2

to_artwork_pixels :: proc(size_points: f32) -> int {
	pixels := int(ui.to_pixels(size_points))

	return (pixels + ARTWORK_STEP_PIXELS - 1) / ARTWORK_STEP_PIXELS * ARTWORK_STEP_PIXELS
}

// Where a box inside a scrolling page starts, in the page's content, as of last frame.
offset_in_page :: proc(page, box: ^ui.Box) -> f32 {
	return box.rect.y - page.rect.y - page.style.padding.y + page.scroll
}

// The library's songs, every page of them, read once per answer version. The command palette shares them.
list_library_songs :: proc() -> (songs: []Catalog_Song, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/songs?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)
	if is_stale && phase == .Ready do read_library_songs(data, bodies)

	return data.songs, signature, phase
}

build_songs_page :: proc() {
	songs, _, phase := list_library_songs()
	build_song_list_page("Songs", "", songs, phase)
}

// Favourite Songs, Songs, Downloaded, every playlist and an artist's Recent Songs. With dates, the
// songs are one artist's, so each row shows its album and its date instead of the artist.
build_song_list_page :: proc(title, description: string, songs: []Catalog_Song, phase: apple.Phase, dates: []string = nil) {
	page := page_scroll("song list")
	run_bench_scroll(page)

	if ui.scope(page) {
		header := ui.box("header", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10, padding = {0, 0, 0, 0}})

		if ui.scope(header) {
			heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(heading) {
				page_heading(title)
				count := fmt.tprintf("%d songs", len(songs))
				if description != "" do count = fmt.tprintf("%s · %s", count, description)
				text_box(count if phase == .Ready else phase_note(phase), colors.dim)
			}

			if phase == .Ready && len(songs) > 0 {
				if action_button("Play", "play.fill", true) do play_songs(songs, 0)
				if action_button("Shuffle", "shuffle", false) do shuffle_songs(songs)
			}
		}

		if phase == .Ready && len(songs) == 0 do note("Nothing here yet.")
		if phase == .Ready do build_song_rows(page, songs, dates)
	}
}

// Only the rows on screen are built. A click plays the list from that song.
build_song_rows :: proc(page: ^ui.Box, songs: []Catalog_Song, dates: []string = nil) {
	rows := ui.box("rows", {width = ui.fill(), height = ui.fit_children(), axis = .Y})
	top := offset_in_page(page, rows)
	first := max(0, int((page.scroll - top) / SONG_ROW_POINTS) - EXTRA_ROW_COUNT)
	last := min(len(songs) - 1, int((page.scroll - top + page.size.y) / SONG_ROW_POINTS) + EXTRA_ROW_COUNT)
	current, is_playing := find_queue_song(app.now_playing.song.persistent_id)

	if ui.scope(rows) {
		if first > 0 do ui.box("", {width = ui.fill(), height = ui.points(f32(first) * SONG_ROW_POINTS)})

		for index in first ..= last {
			song := songs[index]
			is_current := is_playing && is_same_queue_song(current, song)
			subtitle := song.album_name if dates != nil else to_song_subtitle(song)
			date := to_date_text(dates[index]) if index < len(dates) else ""
			if build_song_row(fmt.tprintf("%d %s", index, song.id), song, subtitle, is_current, date) do play_songs(songs, index)
		}

		if last < len(songs) - 1 do ui.box("", {width = ui.fill(), height = ui.points(f32(len(songs) - 1 - last) * SONG_ROW_POINTS)})
	}
}

// A video on YouTube has no album.
to_song_subtitle :: proc(song: Catalog_Song) -> string {
	return fmt.tprintf("%s · %s", song.artist_name, song.album_name) if song.album_name != "" else song.artist_name
}

// Returns true when clicked. A date, when given, sits before the heart.
build_song_row :: proc(id: string, song: Catalog_Song, subtitle: string, is_current: bool, date := "") -> bool {
	tint := to_accent_tint(app.accent)
	row := ui.box(id, {
		width            = ui.fill(),
		height           = ui.points(SONG_ROW_POINTS),
		axis             = .X,
		align            = .Center,
		gap              = 11,
		padding          = {6, 0, 6, 0},
		corner_radius    = 7,
		background       = tint if is_current else {},
		hover_background = tint if is_current else colors.hover,
		press_background = colors.selected,
		flags            = {.Clickable},
	})

	if ui.scope(row) {
		artwork_box(apple.to_artwork_url(song.artwork, to_artwork_pixels(SONG_ARTWORK_POINTS)), SONG_ARTWORK_POINTS, 5, to_placeholder(song.artwork, song.album_name))

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			text_box(song.name, app.accent if is_current else colors.text)
			text_box(subtitle, colors.dim, 12)
		}

		if date != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.faint, font_size = 12}, date)
		build_row_heart(row, song, is_current)
		ui.box("", {width = ui.points(44), height = ui.fit_text(), text_align = .End, text_color = colors.faint, font_size = 12}, to_clock_text(song.duration_seconds))
	}

	return track_song_row(ui.signal(row), song)
}

// Filled in the accent for a favourite, an empty outline for any other, on song lists and albums. A YouTube
// song Apple has takes the heart of Apple's song. One Apple lacks shows YouTube's mark, dim while it is checked.
build_row_heart :: proc(row: ^ui.Box, chosen: Catalog_Song, is_current: bool) {
	song, state := find_match(chosen)

	if state != .Found {
		color := colors.youtube if state == .Missing else colors.faint
		// The same padding as the heart's button, so the lengths after it line up.
		icon_box("", YOUTUBE_SYMBOL, 13, color, {padding = {4, 4, 4, 4}})
		return
	}

	persistent_id := app.now_playing.song.persistent_id if is_current else ""
	is_on := is_favourite(song, persistent_id)

	if favourite_button("heart", is_on, 13) do toggle_favourite(song, persistent_id)
}

list_library_albums :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/albums?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)
	if is_stale && phase == .Ready do read_cards(data, bodies)

	return data.cards, signature, phase
}

build_albums_page :: proc() {
	cards, _, phase := list_library_albums()
	build_card_grid_page("Albums", cards, phase, false)
}

build_artists_page :: proc() {
	cards, _, phase := list_library_artists()
	build_card_grid_page("Artists", cards, phase, true)
}

// Two library artists can share one catalog artist, such as a name spelled two ways. It shows once.
list_library_artists :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/artists?sort=name&include=catalog"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)

	if is_stale && phase == .Ready {
		allocator := page_allocator(data)
		cards := make([dynamic]apple.Card, allocator)
		seen := make(map[string]bool, context.temp_allocator)

		for body in bodies {
			for artist in apple.to_resources(body, allocator) {
				catalog := apple.list_related(artist, "catalog")
				if len(catalog) == 0 || seen[catalog[0].id] do continue

				seen[catalog[0].id] = true
				append(&cards, apple.to_card(catalog[0]))
			}
		}
		data.cards = cards[:]
	}

	return data.cards, signature, phase
}

build_recently_added_page :: proc() {
	path := "/v1/me/library/recently-added?limit=25"
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)
	if is_stale && watched.phase == .Ready do read_cards(data, {watched.body})

	build_card_grid_page("Recently Added", data.cards, watched.phase, false)
}

build_card_grid_page :: proc(title: string, cards: []apple.Card, phase: apple.Phase, is_round: bool) {
	page := page_scroll("grid page")
	run_bench_scroll(page)

	if ui.scope(page) {
		heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

		if ui.scope(heading) {
			page_heading(title)
			text_box(fmt.tprintf("%d items", len(cards)) if phase == .Ready else phase_note(phase), colors.dim)
		}

		if phase == .Ready do build_card_grid(page, cards, is_round)
	}
}

// Rows of whole tiles that fill the page's width. Only the rows on screen are built.
build_card_grid :: proc(page: ^ui.Box, cards: []apple.Card, is_round: bool) {
	width := page.size.x - page.style.padding.x - page.style.padding.z
	grid := ui.box("grid", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

	if width <= 0 do return

	tile := fit_tile_size(width, TARGET_TILE_POINTS, TILE_GAP_POINTS)
	columns := max(1, int((width + TILE_GAP_POINTS) / (tile + TILE_GAP_POINTS)))
	row_points := tile + TILE_TEXT_POINTS + TILE_GAP_POINTS
	row_count := (len(cards) + columns - 1) / columns
	top := offset_in_page(page, grid)
	first := max(0, int((page.scroll - top) / row_points) - 1)
	last := min(row_count - 1, int((page.scroll - top + page.size.y) / row_points) + 1)

	if ui.scope(grid) {
		if first > 0 do ui.box("", {width = ui.fill(), height = ui.points(f32(first) * row_points)})

		for row in first ..= last {
			row_box := ui.box(fmt.tprintf("row %d", row), {width = ui.fill(), height = ui.points(row_points), axis = .X, gap = TILE_GAP_POINTS})

			if ui.scope(row_box) {
				for column in 0 ..< columns {
					index := row * columns + column
					if index >= len(cards) do break
					if build_card_tile(fmt.tprintf("%d %s", index, cards[index].id), cards[index], tile, is_round) do open_card(cards, index)
				}
			}
		}

		if last < row_count - 1 do ui.box("", {width = ui.fill(), height = ui.points(f32(row_count - 1 - last) * row_points)})
	}
}

// Favourite Songs is the one library playlist a person can neither edit nor delete. The sidebar leaves it out.
list_playlists :: proc() -> (playlists: []apple.Card, favourite_songs_id: string, phase: apple.Phase) {
	path := "/v1/me/library/playlists?limit=100"
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		allocator := page_allocator(data)
		cards := make([dynamic]apple.Card, allocator)

		for resource in apple.to_resources(watched.body, allocator) {
			can_edit, has_edit := resource.attributes.can_edit.?
			can_delete, has_delete := resource.attributes.can_delete.?

			if has_edit && has_delete && !can_edit && !can_delete {
				data.link_id = resource.id
				continue
			}
			append(&cards, apple.to_card(resource))
		}
		data.cards = cards[:]
	}

	return data.cards, data.link_id, watched.phase
}
