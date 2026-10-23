package app

import "core:fmt"
import "core:strconv"
import "om:app/core"
import "om:app/kit"
import "om:platform"
import "om:store"

zoom_steps := [?]f32{0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2}

SAVED_ZOOM_TOLERANCE :: 0.001

start_saved_window_state :: proc() {
	core.app.last_panel = .Up_Next

	if saved, has_panel := store.find_state("panel", context.temp_allocator); has_panel {
		for text, panel in core.saved_panels do if text == saved do core.set_panel(panel)
	}

	zoom, has_zoom := store.find_state("zoom", context.temp_allocator)
	if !has_zoom do return

	value, is_number := strconv.parse_f32(zoom)
	if !is_number do return

	for step in zoom_steps do if abs(step - value) < SAVED_ZOOM_TOLERANCE do core.app.zoom = step
}

to_nearest_zoom_step :: proc(zoom: f32) -> int {
	nearest := 0

	for step, index in zoom_steps {
		if abs(step - zoom) < abs(zoom_steps[nearest] - zoom) do nearest = index
	}

	return nearest
}

to_smaller_zoom :: proc(zoom: f32) -> f32 {
	return zoom_steps[max(to_nearest_zoom_step(zoom) - 1, 0)]
}

set_zoom :: proc(zoom: f32) {
	if zoom > core.app.zoom && !is_zoom_fitting(zoom) do return

	core.app.zoom = zoom
	store.save_state("zoom", fmt.tprintf("%g", zoom))
	set_min_window_size()
}

set_min_window_size :: proc() {
	platform.set_min_size(to_min_window_size(core.app.zoom))
}

is_zoom_fitting :: proc(zoom: f32) -> bool {
	min_size := to_min_window_size(zoom)
	screen := platform.read_screen_size_points()

	return min_size.x <= screen.x && min_size.y <= screen.y
}

to_min_window_size :: proc(zoom: f32) -> [2]f32 {
	return {kit.MIN_WINDOW_WIDTH_POINTS, kit.MIN_WINDOW_HEIGHT_POINTS} * zoom
}
