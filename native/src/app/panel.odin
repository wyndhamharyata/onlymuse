package app

import "core:fmt"
import "om:apple"
import "om:ui"

// Returns true while the lyrics move.
build_panel :: proc() -> bool {
	is_open := app.panel != .None
	width := ui.animate("panel width", PANEL_WIDTH_POINTS if is_open else 0)

	if width < 1 do return false

	panel := ui.box("panel", {
		width      = ui.points(width),
		height     = ui.fill(),
		axis       = .Y,
		padding    = {16, 14, 16, 0},
		gap        = 4,
		background = colors.panel,
		fade       = 1 - width / PANEL_WIDTH_POINTS,
		flags      = {.Clip},
	})
	is_moving := false
	inner_width: f32 = PANEL_WIDTH_POINTS - 32

	if ui.scope(panel) {
		inner := ui.box("inner", {width = ui.points(inner_width), height = ui.fill(), axis = .Y, gap = 4})

		if ui.scope(inner) {
			#partial switch app.panel {
			case .Lyrics:
				is_moving = build_lyrics()
			case .Up_Next:
				build_up_next()
			}
		}
	}

	return is_moving
}

build_up_next :: proc() {
	if len(queue.songs) == 0 || queue.index < 0 {
		build_panel_note("Play a song or an album, and the songs after it show here.")
		return
	}

	list := ui.box("up next", {width = ui.fill(), height = ui.fill(), axis = .Y, gap = 2, padding = {0, 0, 0, 16}, flags = {.Scroll, .Clip}})
	row_points: f32 = 52
	first_row := max(queue.index, queue.index + int(list.scroll / row_points) - EXTRA_ROW_COUNT)
	last_row := min(len(queue.songs) - 1, queue.index + int((list.scroll + list.size.y) / row_points) + EXTRA_ROW_COUNT)

	if ui.scope(list) {
		ui.box("", {width = ui.fill(), height = ui.points(f32(first_row - queue.index) * row_points)})

		for index in first_row ..= last_row do build_queue_row(index, row_points)

		ui.box("", {width = ui.fill(), height = ui.points(f32(len(queue.songs) - 1 - last_row) * row_points)})
	}
}

build_queue_row :: proc(index: int, row_points: f32) {
	song := queue.songs[index]
	is_current := index == queue.index
	tint := to_accent_tint(app.accent)
	row := ui.box(fmt.tprintf("queue %d %s", index, song.id), {
		width            = ui.fill(),
		height           = ui.points(row_points - 2),
		axis             = .X,
		align            = .Center,
		gap              = 10,
		padding          = {8, 0, 4, 0},
		corner_radius    = 6,
		background       = tint if is_current else {},
		hover_background = tint if is_current else colors.hover,
		flags            = {.Clickable},
	})
	is_removed := false

	if ui.scope(row) {
		artwork_box(apple.to_artwork_url(song.artwork, to_artwork_pixels(36)), 36, 4, to_placeholder(song.artwork, song.album_name))

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			text_box(song.name, app.accent if is_current else colors.text, weight = .Medium)
			text_box(song.artist_name, colors.dim, 12)
		}

		// The song playing stays. Another shows its remove button while hovered.
		if !is_current && row.hot_t > 0.01 {
			is_removed = icon_button("remove", "xmark", 11, {colors.dim.r, colors.dim.g, colors.dim.b, row.hot_t})
		}
	}

	if is_removed {
		remove_from_queue(index)
	} else if ui.signal(row).is_clicked {
		play_queue_at(index)
	}
}
