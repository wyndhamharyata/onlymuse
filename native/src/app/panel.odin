package app

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
		tabs := ui.box("tabs", {width = ui.points(inner_width), height = ui.points(36), axis = .X, gap = 4, padding = {0, 0, 0, 10}})

		if ui.scope(tabs) {
			if build_tab("Up Next", app.panel == .Up_Next) do app.panel = .Up_Next
			if build_tab("Lyrics", app.panel == .Lyrics) do app.panel = .Lyrics
		}

		inner := ui.box("inner", {width = ui.points(inner_width), height = ui.fill(), axis = .Y, gap = 4})

		if ui.scope(inner) {
			#partial switch app.panel {
			case .Lyrics:
				is_moving = build_lyrics()
			case .Up_Next:
				build_panel_note("The queue comes in the next step.")
			}
		}
	}

	return is_moving
}

// Returns true when clicked.
build_tab :: proc(label: string, is_selected: bool) -> bool {
	tint := to_accent_tint(app.accent)
	tab := ui.box(label, {
		width            = ui.fit_text(),
		height           = ui.fill(),
		padding          = {12, 0, 12, 0},
		corner_radius    = 13,
		background       = tint if is_selected else {},
		hover_background = tint if is_selected else colors.hover,
		text_color       = app.accent if is_selected else colors.text,
		font_weight      = .Semibold,
		flags            = {.Clickable},
	}, label)

	return ui.signal(tab).is_clicked
}
