package app

import "core:fmt"
import "core:strconv"
import "om:app/core"
import "om:app/kit"
import "om:platform"
import "om:store"

// The zoom of the whole window, as in a browser.
zoom_steps := [?]f32{0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2}

// The panel and the zoom of the last run.
start_saved_window_state :: proc() {
	core.app.last_panel = .Up_Next

	if panel, ok := store.find_state("panel", context.temp_allocator); ok {
		switch panel {
		case `"lyrics"`:
			core.app.panel = .Lyrics
			core.app.last_panel = .Lyrics
		case `"queue"`:
			core.app.panel = .Up_Next
		case "null":
			core.app.panel = .None
		}
	}

	if zoom, ok := store.find_state("zoom", context.temp_allocator); ok {
		value, is_number := strconv.parse_f32(zoom)
		for step in zoom_steps do if is_number && abs(step - value) < 0.001 do core.app.zoom = step
	}
}

// The step nearest the zoom.
find_zoom_step :: proc() -> int {
	nearest := 0
	for step, index in zoom_steps {
		if abs(step - core.app.zoom) < abs(zoom_steps[nearest] - core.app.zoom) {
			nearest = index
		}
	}

	return nearest
}

// Zooming in stops at the step whose smallest window no longer fits on the screen.
set_zoom :: proc(zoom: f32) {
	if zoom > core.app.zoom && !does_zoom_fit(zoom) do return

	core.app.zoom = zoom
	store.save_state("zoom", fmt.tprintf("%g", zoom))
	apply_min_window_size()
}

// The sidebar, a page and the side panel fit side by side in the smallest window at any zoom, because the
// smallest window grows with the zoom.
apply_min_window_size :: proc() {
	platform.set_min_size(to_min_window_size(core.app.zoom))
}

does_zoom_fit :: proc(zoom: f32) -> bool {
	min_size := to_min_window_size(zoom)
	screen := platform.screen_size_points()

	return min_size.x <= screen.x && min_size.y <= screen.y
}

to_min_window_size :: proc(zoom: f32) -> [2]f32 {
	return {kit.MIN_WINDOW_WIDTH_POINTS, kit.MIN_WINDOW_HEIGHT_POINTS} * zoom
}
