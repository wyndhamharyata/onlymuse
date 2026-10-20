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
		padding    = {8, 8, 8, 8},
		gap        = 4,
		background = colors.panel,
		fade       = 1 - width / PANEL_WIDTH_POINTS,
		flags      = {.Clip},
	})
	is_moving := false
	inner_width: f32 = PANEL_WIDTH_POINTS - 16

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

		ui.box("", {width = ui.points(1), height = ui.points(4)})
		build_panel_tabs(inner_width)
	}

	return is_moving
}

build_up_next :: proc() {
	if len(queue.songs) == 0 || queue.index < 0 {
		build_panel_note("Play a song or an album, and the songs after it show here.")
		return
	}

	if queue.is_shuffled {
		note_row := ui.box("shuffle note", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 8, padding = {6, 2, 2, 6}})

		if ui.scope(note_row) {
			icon_box("", "shuffle", 11, app.accent)
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, font_size = 11.5, flags = {.Wrap_Text}}, shuffle_note if shuffle_note != "" else "Shuffled.")
			rules := ui.box("rules", {width = ui.fit_text(), height = ui.points(22), padding = {8, 0, 8, 0}, corner_radius = 6, background = colors.field, hover_background = colors.hover, text_color = colors.text, font_size = 11.5, font_weight = .Semibold, flags = {.Clickable}}, "Rules")
			if ui.signal(rules).is_clicked do open_shuffle_rules({rules.rect.x - 240, rules.rect.w + 4})
		}
	}

	list := ui.box("up next", {width = ui.fill(), height = ui.fill(), axis = .Y, gap = 2, flags = {.Scroll, .Clip}})
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
		padding          = {6, 0, 4, 0},
		corner_radius    = 6,
		background       = tint if is_current else {},
		hover_background = tint if is_current else colors.hover,
		flags            = {.Clickable},
	})
	is_removed := false

	if ui.scope(row) {
		artwork_box(apple.to_artwork_url(song.artwork, to_artwork_pixels(36)), 36, 4, to_placeholder(song.artwork, song.album_name))

		text := ui.box("text", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			is_hovered := ui.signal(row).is_hovered
			scrolling_text("name", song.name, app.accent if is_current else colors.text, 13, .Medium, is_hovered = is_hovered)
			scrolling_text("artist", song.artist_name, colors.dim, 12, is_hovered = is_hovered)
		}

		build_row_heart(row, song, is_current)

		// The song playing stays. Another shows its remove button while hovered.
		if !is_current && is_mouse_in(row) {
			is_removed = icon_button("remove", "xmark", 11, colors.dim)
		}
	}

	if is_removed {
		remove_from_queue(index)
	} else if track_song_row(ui.signal(row), song) {
		play_queue_at(index)
	}
}

// Picks what the side panel shows. The button by the volume shows and hides it.
build_panel_tabs :: proc(width: f32) {
	tabs := ui.box("panel tabs", {
		width         = ui.points(width),
		height        = ui.points(30),
		axis          = .X,
		gap           = 2,
		padding       = {2, 2, 2, 2},
		corner_radius = 9,
		background    = colors.field,
	})

	if ui.scope(tabs) {
		build_panel_tab("Up Next", "list.bullet", .Up_Next)
		build_panel_tab("Lyrics", "quote.bubble", .Lyrics)
	}
}

@(private = "file")
build_panel_tab :: proc(label, symbol: string, panel: Panel) {
	is_open := app.panel == panel
	tint := to_accent_tint(app.accent)
	tab := ui.box(label, {
		width            = ui.fill(),
		height           = ui.fill(),
		axis             = .X,
		align            = .Center,
		gap              = 6,
		padding          = {10, 0, 10, 0},
		corner_radius    = 7,
		background       = tint if is_open else {},
		hover_background = tint if is_open else colors.hover,
		press_background = colors.selected,
		flags            = {.Clickable},
	})

	if ui.signal(tab).is_clicked do set_panel(panel)

	if ui.scope(tab) {
		spacer()
		color := app.accent if is_open else colors.dim
		icon_box("", symbol, 13, color)
		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent if is_open else colors.text, font_size = 12.5, font_weight = .Semibold}, label)
		spacer()
	}
}
