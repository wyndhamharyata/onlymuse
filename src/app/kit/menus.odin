package kit

import "core:fmt"
import "om:app/core"
import "om:ui"

MENU_ITEM_HEIGHT_POINTS :: 26

MENU_MARGIN_POINTS :: 8

menu_box :: proc(id: string, position: [2]f32, width: f32, window_size: [2]f32) -> ^ui.Box {
	existing := ui.find_box(id, ui.current_parent())
	height: f32 = existing.size.y if existing != nil else 200
	max_x := window_size.x - width - MENU_MARGIN_POINTS
	max_y := max(MENU_MARGIN_POINTS, window_size.y - height - MENU_MARGIN_POINTS)
	x := clamp(position.x, MENU_MARGIN_POINTS, max_x)
	y := clamp(position.y, MENU_MARGIN_POINTS, max_y)

	ui.box(
		fmt.tprintf("%s shadow", id),
		{
			width = ui.points(width),
			height = ui.points(height),
			corner_radius = 12,
			background = {0, 0, 0, 0.45},
			softness = 24,
			position = {x, y + 8},
			flags = {.Floating},
		},
	)

	return ui.box(
		id,
		{
			width = ui.points(width),
			height = ui.fit_children(),
			axis = .Y,
			gap = 1,
			padding = {5, 5, 5, 5},
			corner_radius = 10,
			background = colors.popover,
			border_width = 1,
			border_color = colors.popover_border,
			position = {x, y},
			flags = {.Floating, .Clickable},
		},
	)
}

menu_item_signal :: proc(id, label, hint: string, is_selected: bool, color: [4]f32) -> ui.Signal {
	item := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.points(MENU_ITEM_HEIGHT_POINTS),
			axis = .X,
			align = .Center,
			padding = {9, 0, 9, 0},
			corner_radius = 6,
			background = core.app.accent if is_selected else {},
			hover_background = core.app.accent,
			flags = {.Clickable},
		},
	)

	text_color := color if color.a > 0 else colors.text
	has_accent_fill := is_selected || item.hot_fraction > 0.5
	if has_accent_fill do text_color = colors.white

	if ui.scope(item) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = text_color,
				font_size = 13,
				flags = {.Truncate_Text},
			},
			label,
		)

		if hint != "" {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = text_color if is_selected else colors.faint,
					font_size = 12,
				},
				hint,
			)
		}
	}

	return ui.signal(item)
}

menu_item :: proc(id, label: string, hint := "", color := [4]f32{}) -> bool {
	return menu_item_signal(id, label, hint, false, color).is_clicked
}

menu_separator :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1), background = to_color(0xffffff14)})
}
