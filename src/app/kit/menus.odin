package kit

import "core:fmt"
import "om:app/core"
import "om:ui"

MENU_ITEM_POINTS :: 26

// A menu's panel, kept inside the window.
menu_box :: proc(id: string, position: [2]f32, width: f32, window_size: [2]f32) -> ^ui.Box {
	existing := ui.find_box(id, ui.current_parent())
	height: f32 = existing.size.y if existing != nil else 200
	x := clamp(position.x, 8, window_size.x - width - 8)
	y := clamp(position.y, 8, max(8, window_size.y - height - 8))

	ui.box(fmt.tprintf("%s shadow", id), {width = ui.points(width), height = ui.points(height), corner_radius = 12, background = {0, 0, 0, 0.45}, softness = 24, position = {x, y + 8}, flags = {.Floating}})

	return ui.box(id, {
		width         = ui.points(width),
		height        = ui.fit_children(),
		axis          = .Y,
		gap           = 1,
		padding       = {5, 5, 5, 5},
		corner_radius = 10,
		background    = to_color(0x2c2c31f5),
		border_width  = 1,
		border_color  = to_color(0xffffff1c),
		position      = {x, y},
		flags         = {.Floating, .Clickable},
	})
}

// A selected item, such as the open submenu's, takes the accent.
menu_item_signal :: proc(id, label: string, hint := "", is_selected := false, color := [4]f32{}) -> ui.Signal {
	item := ui.box(id, {
		width            = ui.fill(),
		height           = ui.points(MENU_ITEM_POINTS),
		axis             = .X,
		align            = .Center,
		padding          = {9, 0, 9, 0},
		corner_radius    = 6,
		background       = core.app.accent if is_selected else {},
		hover_background = core.app.accent,
		flags            = {.Clickable},
	})
	text_color := color if color.a > 0 else colors.text
	if is_selected || item.hot_t > 0.5 do text_color = to_color(0xffffffff)

	if ui.scope(item) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = text_color, font_size = 13, flags = {.Truncate_Text}}, label)
		if hint != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = text_color if is_selected else colors.faint, font_size = 12}, hint)
	}

	return ui.signal(item)
}

menu_item :: proc(id, label: string, hint := "", is_selected := false, color := [4]f32{}) -> bool {
	return menu_item_signal(id, label, hint, is_selected, color).is_clicked
}

menu_separator :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1), background = to_color(0xffffff14)})
}
