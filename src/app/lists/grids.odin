package lists

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:app/playback"
import "om:apple"
import "om:ui"

// A grid column narrower than these leaves a song's name no room: the grid takes one column, and a row
// leaves out its date.
MIN_GRID_COLUMN_POINTS :: 300

MIN_DATED_COLUMN_POINTS :: 420

GRID_GAP_POINTS :: 20

// Two columns, filled row by row, or one when the page is narrow. A click plays all of playing from
// that song. With dates, each row shows its date, when there is room for it.
build_song_grid :: proc(
	songs: []core.Catalog_Song,
	dates: []string,
	playing: []core.Catalog_Song,
) {
	grid := ui.box(
		"grid",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = GRID_GAP_POINTS},
	)
	current, is_playing := playback.find_queue_song(core.app.now_playing.song.persistent_id)
	// The grid's width from the last frame, 0 on the first.
	width := grid.size.x
	column_count := 1 if width > 0 && (width - GRID_GAP_POINTS) / 2 < MIN_GRID_COLUMN_POINTS else 2
	column_width := (width - GRID_GAP_POINTS * f32(column_count - 1)) / f32(column_count)
	has_dates := width <= 0 || column_width >= MIN_DATED_COLUMN_POINTS

	if ui.scope(grid) {
		for column in 0 ..< column_count {
			column_box := ui.box(
				fmt.tprintf("column %d", column),
				{width = ui.fill(), height = ui.fit_children(), axis = .Y},
			)

			if ui.scope(column_box) {
				for index := column; index < len(songs); index += column_count {
					song := songs[index]
					date :=
						kit.to_date_text(dates[index]) if has_dates && index < len(dates) else ""

					if build_song_row(
						fmt.tprintf("%d %s", index, song.id),
						song,
						song.album_name,
						is_playing && matching.is_same_queue_song(current, song),
						date,
					) {
						playback.play_songs(playing, index)
					}
				}
			}
		}
	}
}

// The tile size that fits a whole number of tiles across, as close to this as it can.
TARGET_TILE_POINTS :: 160

TILE_GAP_POINTS :: 14

// The title and the artist under a tile.
TILE_TEXT_POINTS :: 46

build_card_grid_page :: proc(
	title: string,
	cards: []apple.Card,
	phase: apple.Phase,
	is_round: bool,
) {
	page := kit.page_scroll("grid page")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

		if ui.scope(heading) {
			kit.page_heading(title)
			kit.text_box(
				fmt.tprintf("%d items", len(cards)) if phase == .Ready else kit.phase_note(phase),
				kit.colors.dim,
			)
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
	top := core.offset_in_page(page, grid)
	first := max(0, int((page.scroll - top) / row_points) - 1)
	last := min(row_count - 1, int((page.scroll - top + page.size.y) / row_points) + 1)

	if ui.scope(grid) {
		if first > 0 do ui.box("", {width = ui.fill(), height = ui.points(f32(first) * row_points)})

		for row in first ..= last {
			row_box := ui.box(
				fmt.tprintf("row %d", row),
				{
					width = ui.fill(),
					height = ui.points(row_points),
					axis = .X,
					gap = TILE_GAP_POINTS,
				},
			)

			if ui.scope(row_box) {
				for column in 0 ..< columns {
					index := row * columns + column
					if index >= len(cards) do break

					if build_card_tile(
						fmt.tprintf("%d %s", index, cards[index].id),
						cards[index],
						tile,
						is_round,
					) {
						open_card(cards, index)
					}
				}
			}
		}

		if last < row_count - 1 {
			ui.box(
				"",
				{width = ui.fill(), height = ui.points(f32(row_count - 1 - last) * row_points)},
			)
		}
	}
}
