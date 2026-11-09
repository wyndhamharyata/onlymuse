package lists

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

MIN_GRID_COLUMN_POINTS :: 300

MIN_DATED_COLUMN_POINTS :: 420

GRID_GAP_POINTS :: 20

build_song_grid :: proc(
	songs: []core.Catalog_Song,
	dates: []string,
	queue_songs: []core.Catalog_Song,
) {
	grid := ui.box(
		"grid",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = GRID_GAP_POINTS},
	)
	width := grid.size.x
	is_narrow := width > 0 && (width - GRID_GAP_POINTS) / 2 < MIN_GRID_COLUMN_POINTS
	column_count := 1 if is_narrow else 2
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
						look.to_date_text(dates[index]) if has_dates && index < len(dates) else ""

					if build_song_row(
						fmt.tprintf("%d %s", index, song.id),
						song,
						song.album_name,
						playback.is_current_song(song),
						date,
					) {
						playback.play_songs(queue_songs, index)
					}
				}
			}
		}
	}
}

TARGET_TILE_POINTS :: 160

TILE_TEXT_POINTS :: 46

build_card_grid_page :: proc(
	title: string,
	cards: []apple.Card,
	phase: apple.Phase,
	is_round: bool,
) {
	page := look.page_scroll("grid page")
	look.run_bench_scroll(page)

	if ui.scope(page) {
		heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

		if ui.scope(heading) {
			kit.heading(title)
			kit.text(
				fmt.tprintf("%d items", len(cards)) if phase == .Ready else look.to_phase_text(phase),
				kit.colors.dim,
			)
		}

		if phase == .Loading do look.build_loading(title)
		if phase == .Ready do build_card_grid(page, cards, is_round)
	}
}

build_card_grid :: proc(page: ^ui.Box, cards: []apple.Card, is_round: bool) {
	width := look.to_content_width(page)
	if width <= 0 do return

	tile_points := to_tile_size(width, TARGET_TILE_POINTS, CARD_GAP_POINTS)
	column_count := max(1, int((width + CARD_GAP_POINTS) / (tile_points + CARD_GAP_POINTS)))
	row_points := tile_points + TILE_TEXT_POINTS + CARD_GAP_POINTS
	row_count := (len(cards) + column_count - 1) / column_count
	style := ui.Style {
		width  = ui.fill(),
		height = ui.fit_children(),
	}

	if first, last, ok := kit.list("grid", row_count, row_points, style); ok {
		for row in first ..< last {
			row_box := ui.box(
				fmt.tprintf("row %d", row),
				{
					width = ui.fill(),
					height = ui.points(row_points),
					axis = .X,
					gap = CARD_GAP_POINTS,
				},
			)

			if ui.scope(row_box) {
				for column in 0 ..< column_count {
					index := row * column_count + column
					if index >= len(cards) do break

					if build_card_tile(
						fmt.tprintf("%d %s", index, cards[index].id),
						cards[index],
						tile_points,
						is_round,
					) {
						open_card(cards, index)
					}
				}
			}
		}
	}
}
