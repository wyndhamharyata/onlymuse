package look

import "core:fmt"
import "thor:kit"
import "thor:ui"

// A song's menu opens its playlists beside it as a submenu, and kit.popover cannot nest.
menu_box :: proc(id: string, position: [2]f32, width: f32, window_size: [2]f32) -> ^ui.Box {
	existing := ui.find_box(id, ui.current_parent())
	height: f32 = existing.size.y if existing != nil else 200
	max_x := window_size.x - width - kit.MENU_MARGIN_POINTS
	max_y := max(kit.MENU_MARGIN_POINTS, window_size.y - height - kit.MENU_MARGIN_POINTS)
	x := clamp(position.x, kit.MENU_MARGIN_POINTS, max_x)
	y := clamp(position.y, kit.MENU_MARGIN_POINTS, max_y)

	ui.box(
		fmt.tprintf("%s_shadow", id),
		{
			width = ui.points(width),
			height = ui.points(height),
			corner_radius = kit.shape.radius_box + 2,
			background = kit.colors.shadow,
			softness = 24,
			position = {x, y + 8},
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
			background = kit.colors.popover,
			border_width = kit.shape.border,
			border_color = kit.to_faded(kit.colors.base_content, kit.LINE_OPACITY),
			position = {x, y},
			flags = {.Floating, .Clickable},
		},
	)
	menu.role, menu.label = .Popover, id

	return menu
}
