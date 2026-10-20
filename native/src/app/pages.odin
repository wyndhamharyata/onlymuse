package app

import "core:fmt"
import "core:math"
import "om:apple"
import "om:library"
import "om:ui"

// The tile size that fits a whole number of tiles across, as close to this as it can.
TARGET_TILE_POINTS :: 160
TILE_GAP_POINTS :: 18
// The title and the artist under a tile.
TILE_TEXT_POINTS :: 46
// Artwork is asked for in steps of this many pixels, so a resized window reuses the saved files.
ARTWORK_STEP_PIXELS :: 100
SONG_ROW_POINTS :: 52
// Rows built past each edge of a list, so a fast scroll finds them ready.
EXTRA_ROW_COUNT :: 2

page_titles := [Page_Kind]string {
	.Home            = "Home",
	.New             = "New",
	.Favourite_Songs = "Favourite Songs",
	.Recently_Added  = "Recently Added",
	.Artists         = "Artists",
	.Albums          = "Albums",
	.Songs           = "Songs",
	.Downloaded      = "Downloaded",
	.Playlist        = "Playlist",
	.Catalog_Playlist = "Playlist",
	.Album           = "Album",
	.Artist          = "Artist",
	.Search          = "Search",
}

build_page_area :: proc() {
	area := ui.box("page area", {width = ui.fill(), height = ui.fill(), axis = .Y})

	if ui.scope(area) {
		toolbar := ui.box("toolbar", {width = ui.fill(), height = ui.points(TOOLBAR_HEIGHT_POINTS), axis = .X, align = .Center, gap = 4, padding = {18, 0, 0, 0}})

		if ui.scope(toolbar) {
			if icon_button("back", "chevron.left", 16, colors.text, can_go_back()) do go_back()
			if icon_button("forward", "chevron.right", 16, colors.text, can_go_forward()) do go_forward()
		}

		page := current_page()
		// Each page keeps its own scroll, as its boxes are keyed under its own ID.
		page_box := ui.box(fmt.tprintf("page %v %s", page.kind, page.id), {width = ui.fill(), height = ui.fill(), axis = .Y})

		if ui.scope(page_box) {
			#partial switch page.kind {
			case .Home:
				build_shelves_page("Home", apple.HOME_PATH, false)
			case .New:
				build_shelves_page("New", apple.NEW_PATH, true)
			case .Albums:
				build_albums()
			case .Songs:
				build_song_list(app.songs, app.queue_songs)
			case .Album:
				build_album_page(page.id)
			case .Playlist, .Catalog_Playlist:
				build_playlist_page(page)
			case .Favourite_Songs:
				build_favourite_songs_page()
			case .Recently_Added:
				build_recently_added_page()
			case:
				build_page_title(page.title if page.title != "" else page_titles[page.kind])
				build_page_note("This page comes in a later step.")
			}
		}
	}
}

build_page_title :: proc(title: string) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), padding = {PAGE_PADDING_POINTS, 0, PAGE_PADDING_POINTS, 14}, text_color = colors.text, font_size = 26, font_weight = .Bold, flags = {.Truncate_Text}}, title)
}

build_page_note :: proc(text: string) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), padding = {PAGE_PADDING_POINTS, 0, PAGE_PADDING_POINTS, 0}, text_color = colors.dim, flags = {.Wrap_Text}}, text)
}

build_albums :: proc() {
	grid := ui.box("albums", {width = ui.fill(), height = ui.fill(), axis = .Y, padding = {PAGE_PADDING_POINTS, 0, PAGE_PADDING_POINTS, PAGE_PADDING_POINTS}, flags = {.Scroll, .Clip}})

	run_bench_scroll(grid)

	// The width the grid had last frame.
	width := grid.size.x - grid.style.padding.x - grid.style.padding.z
	column_count := max(1, int(math.round((width + TILE_GAP_POINTS) / (TARGET_TILE_POINTS + TILE_GAP_POINTS))))
	tile_points := math.floor((width - TILE_GAP_POINTS * f32(column_count - 1)) / f32(column_count))
	row_points := tile_points + TILE_TEXT_POINTS + TILE_GAP_POINTS
	row_count := (len(app.albums) + column_count - 1) / column_count
	title_points: f32 = 46
	first_row := max(0, int((grid.scroll - title_points) / row_points) - 1)
	last_row := min(row_count - 1, int((grid.scroll + grid.size.y) / row_points) + 1)

	if ui.scope(grid) {
		ui.box("", {width = ui.fill(), height = ui.points(title_points), text_color = colors.text, font_size = 26, font_weight = .Bold}, "Albums")

		if width <= 0 do return

		ui.box("", {width = ui.fill(), height = ui.points(f32(first_row) * row_points)})

		for row in first_row ..= last_row {
			row_box := ui.box(fmt.tprintf("row %d", row), {width = ui.fill(), height = ui.points(row_points), axis = .X, gap = TILE_GAP_POINTS})

			if ui.scope(row_box) {
				for column in 0 ..< column_count {
					index := row * column_count + column
					if index >= len(app.albums) do break

					build_album_tile(app.albums[index], tile_points)
				}
			}
		}

		ui.box("", {width = ui.fill(), height = ui.points(f32(row_count - 1 - last_row) * row_points)})
	}
}

to_artwork_pixels :: proc(size_points: f32) -> int {
	return int(math.ceil(ui.to_pixels(size_points) / ARTWORK_STEP_PIXELS)) * ARTWORK_STEP_PIXELS
}

build_album_tile :: proc(album: library.Album, tile_points: f32) {
	tile := ui.box(album.id, {width = ui.points(tile_points), height = ui.fit_children(), axis = .Y, gap = 2, flags = {.Clickable}})
	if ui.signal(tile).is_clicked do navigate({kind = .Album, id = album.id, title = album.name})

	if ui.scope(tile) {
		cover := ui.box("", {width = ui.points(tile_points), height = ui.points(tile_points + 6), padding = {0, 0, 0, 6}})

		if ui.scope(cover) {
			pixels := to_artwork_pixels(tile_points)
			artwork_box(library.to_artwork_url(album.artwork_url, pixels), tile_points, 8)
			ui.box("", {width = ui.points(tile_points), height = ui.points(tile_points), corner_radius = 8, background = {1, 1, 1, 0.08 * tile.hot_t}, flags = {.Floating}})
		}

		text_box(album.name, colors.text, weight = .Medium)
		text_box(album.artist_name, colors.dim, 12)
	}
}

// Clicking a song plays the list from it.
build_song_list :: proc(songs: []library.Song, queue_songs: []Catalog_Song) {
	list := ui.box("songs", {width = ui.fill(), height = ui.fill(), axis = .Y, padding = {PAGE_PADDING_POINTS - 10, 0, PAGE_PADDING_POINTS - 10, PAGE_PADDING_POINTS}, flags = {.Scroll, .Clip}})

	run_bench_scroll(list)

	title_points: f32 = 46
	first_row := max(0, int((list.scroll - title_points) / SONG_ROW_POINTS) - EXTRA_ROW_COUNT)
	last_row := min(len(songs) - 1, int((list.scroll + list.size.y) / SONG_ROW_POINTS) + EXTRA_ROW_COUNT)

	if ui.scope(list) {
		ui.box("", {width = ui.fill(), height = ui.points(title_points), padding = {10, 0, 10, 0}, text_color = colors.text, font_size = 26, font_weight = .Bold}, "Songs")
		ui.box("", {width = ui.fill(), height = ui.points(f32(first_row) * SONG_ROW_POINTS)})

		for row in first_row ..= last_row {
			if build_song_row(songs[row], row) do play_songs(queue_songs, row)
		}

		ui.box("", {width = ui.fill(), height = ui.points(f32(len(songs) - 1 - last_row) * SONG_ROW_POINTS)})
	}
}

// Returns true when clicked.
build_song_row :: proc(song: library.Song, row: int) -> bool {
	current, is_playing := find_queue_song(app.now_playing.song.persistent_id)
	is_current := is_playing && current.name == song.name && current.album_name == song.album_name
	tint := to_accent_tint(app.accent)
	row_box := ui.box(fmt.tprintf("song %d", row), {
		width            = ui.fill(),
		height           = ui.points(SONG_ROW_POINTS),
		axis             = .X,
		align            = .Center,
		gap              = 12,
		padding          = {10, 0, 10, 0},
		corner_radius    = 6,
		background       = tint if is_current else {},
		hover_background = tint if is_current else colors.hover,
		press_background = colors.selected,
		flags            = {.Clickable},
	})

	if ui.scope(row_box) {
		artwork_box(library.to_artwork_url(song.artwork_url, to_artwork_pixels(36)), 36, 4)

		text := ui.box("", {width = ui.fill(2), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			text_box(song.name, app.accent if is_current else colors.text, weight = .Medium)
			text_box(song.artist_name, colors.dim, 12)
		}

		text_box(song.album_name, colors.dim, 12, width = ui.fill(1))
		ui.box("", {width = ui.points(44), height = ui.fit_text(), text_align = .End, text_color = colors.faint, font_size = 12}, to_clock_text(song.duration_seconds))
	}

	return ui.signal(row_box).is_clicked
}
