package lists

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

MIN_GRID_COLUMN_WIDTH :: 300

MIN_DATED_COLUMN_WIDTH :: 420

GRID_GAP :: 20

build_song_grid :: proc(
	songs: []core.Catalog_Song,
	dates: []string,
	queue_songs: []core.Catalog_Song,
) {
	grid := ui.box("grid", {width = ui.fill(), axis = .X, gap = GRID_GAP})
	width := grid.size.x
	is_narrow := width > 0 && (width - GRID_GAP) / 2 < MIN_GRID_COLUMN_WIDTH
	column_count := 1 if is_narrow else 2
	column_width := (width - GRID_GAP * f32(column_count - 1)) / f32(column_count)
	has_dates := width <= 0 || column_width >= MIN_DATED_COLUMN_WIDTH

	if ui.scope(grid) {
		for column in 0 ..< column_count {
			column_box := ui.box(fmt.tprintf("column_%d", column), {width = ui.fill(), axis = .Y})

			if ui.scope(column_box) {
				for index := column; index < len(songs); index += column_count {
					song := songs[index]
					date :=
						look.to_date_text(dates[index]) if has_dates && index < len(dates) else ""

					if build_song_row(
						fmt.tprintf("%d_%s", index, song.id),
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

// At the usual window widths, a tile is about 160 points wide.
MIN_TILE_WIDTH :: 140

TILE_TEXT_HEIGHT :: 46

build_card_grid_page :: proc(
	title: string,
	cards: []apple.Card,
	phase: apple.Phase,
	is_round: bool,
) {
	page := look.page_scroll("grid_page")
	if ui.scope(page) {
		heading := ui.box("heading", {width = ui.fill(), axis = .Y})

		if ui.scope(heading) {
			kit.heading(title)
			kit.description(
				fmt.tprintf("%d items", len(cards)) if phase == .Ready else look.to_phase_text(phase),
			)
		}

		if phase == .Loading do look.build_loading()
		if phase == .Ready do build_card_grid(cards, is_round)
	}
}

build_card_grid :: proc(cards: []apple.Card, is_round: bool) {
	if first, last, tile, ok := kit.grid(
		"grid",
		len(cards),
		MIN_TILE_WIDTH,
		TILE_TEXT_HEIGHT,
		CARD_GAP,
		1,
		style = {width = ui.fill()},
	); ok {
		for index in first ..< last {
			if build_card_tile(
				fmt.tprintf("%d_%s", index, cards[index].id),
				cards[index],
				tile.x,
				is_round,
			) {
				open_card(cards, index)
			}
		}
	}
}
