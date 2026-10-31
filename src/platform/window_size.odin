package platform

import NS "core:sys/darwin/Foundation"

read_screen_size_points :: proc() -> [2]f32 {
	visible := read_visible_frame()

	return {f32(visible.size.width), f32(visible.size.height)}
}

set_min_size :: proc(min_size_points: [2]f32) {
	min_size := NS.Size{NS.Float(min_size_points.x), NS.Float(min_size_points.y)}

	objc_send(nil, state.ns_window, "setContentMinSize:", min_size)

	frame := state.ns_window->frame()
	is_large_enough := frame.size.width >= min_size.width && frame.size.height >= min_size.height

	if is_large_enough do return

	visible := read_visible_frame()
	size := NS.Size{max(frame.size.width, min_size.width), max(frame.size.height, min_size.height)}
	top := frame.origin.y + frame.size.height
	origin := NS.Point{frame.origin.x, top - size.height}

	origin.x = max(
		visible.origin.x,
		min(origin.x, visible.origin.x + visible.size.width - size.width),
	)
	origin.y = max(
		visible.origin.y,
		min(origin.y, visible.origin.y + visible.size.height - size.height),
	)

	objc_send(
		nil,
		state.ns_window,
		"setFrame:display:animate:",
		NS.Rect{origin, size},
		NS.BOOL(true),
		NS.BOOL(!state.is_background),
	)
}

@(private)
read_visible_frame :: proc() -> NS.Rect {
	screen := objc_send(^NS.Screen, state.ns_window, "screen")
	if screen == nil do screen = NS.Screen.mainScreen()

	return screen->visibleFrame()
}
