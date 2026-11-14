package look

import "core:fmt"
import "thor:kit"
import "thor:ui"

// A song's menu opens its playlists beside it as a submenu, and kit.popover cannot nest.
menu_box :: proc(id: string, pos: [2]f32, width: f32, window_size: [2]f32) -> ^ui.Box {
	existing := ui.find_box(id, ui.current_parent())
	height: f32 = existing.size.y if existing != nil else 200
	max_x := window_size.x - width - kit.MENU_MARGIN
	max_y := max(kit.MENU_MARGIN, window_size.y - height - kit.MENU_MARGIN)
	x := clamp(pos.x, kit.MENU_MARGIN, max_x)
	y := clamp(pos.y, kit.MENU_MARGIN, max_y)

	ui.box(
		fmt.tprintf("%s_shadow", id),
		{
			width = ui.points(width),
			height = ui.points(height),
			corner_radius = kit.shape.radius_box + 2,
			bg = kit.colors.shadow,
			softness = 24,
			pos = {x, y + 8},
			flags = {.Floating},
		},
	)

	menu := ui.box(
		id,
		{
			width = ui.points(width),
			height = ui.fit_children(),
			axis = .Y,
			gap = 1,
			padding = {5, 5, 5, 5},
			corner_radius = kit.shape.radius_box,
			bg = kit.colors.popover,
			border_width = kit.shape.border,
			border_color = kit.colors.line,
			pos = {x, y},
			pointer = .Click,
			flags = {.Floating},
		},
	)
	menu.role, menu.label = .Popover, id

	return menu
}
