package app

import "core:fmt"
import "core:os"
import "core:time"
import "om:platform"
import "om:render"

to_color :: proc "contextless" (hex: u32) -> [4]f32 {
	return {f32((hex >> 24) & 0xff) / 255, f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255}
}

colors := struct {
	window, sidebar, card, line, hover: [4]f32,
} {
	window  = to_color(0x1b1b1ed9),
	sidebar = to_color(0xffffff08),
	card    = to_color(0x2a2a2fff),
	line    = to_color(0x2e2e33ff),
	hover   = to_color(0xffffff12),
}

MIN_ZOOM :: 0.5
MAX_ZOOM :: 3.0
ZOOM_STEP :: 0.1

app: struct {
	window:         ^platform.Window,
	zoom:           f32,
	mouse_points:   [2]f32,
	is_logging_frames: bool,
	frame_times:    [dynamic]time.Tick,
	// OM_CAPTURE saves the third frame to this file and quits, for the development tests.
	capture_path:   string,
	frame_count:    int,
}

main :: proc() {
	app.zoom = 1
	app.is_logging_frames = os.get_env("OM_FRAMES", context.temp_allocator) == "1"
	app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	app.window = platform.open_window("onlymuse", {1200, 800}, draw_frame)
	render.start(app.window.device, app.window.layer)
	platform.run()
}

apply_events :: proc() {
	for event in platform.list_events() {
		#partial switch e in event {
		case platform.Mouse_Move:
			app.mouse_points = e.position
		case platform.Key_Press:
			apply_key(e)
		}
	}
}

apply_key :: proc(key: platform.Key_Press) {
	if .Command not_in key.modifiers do return

	switch key.characters {
	case "=", "+":
		app.zoom = min(app.zoom + ZOOM_STEP, MAX_ZOOM)
	case "-":
		app.zoom = max(app.zoom - ZOOM_STEP, MIN_ZOOM)
	case "0":
		app.zoom = 1
	case "q":
		platform.quit()
	}
}

draw_frame :: proc() -> bool {
	apply_events()
	log_frame_time()

	window := app.window
	pixels_per_point := window.pixels_per_point
	size_pixels := window.size_points * pixels_per_point
	// Layout works in points times zoom, and draws in pixels.
	scale := pixels_per_point * app.zoom
	full_clip := [4]f32{0, 0, size_pixels.x, size_pixels.y}

	render.begin_frame(size_pixels)
	render.push({rect = {0, 0, size_pixels.x, size_pixels.y}, color = colors.window, clip = full_clip})
	render.push({rect = {0, 0, 228 * scale, size_pixels.y}, color = colors.sidebar, clip = full_clip})

	card_origin := [2]f32{260, 80} * scale
	card_size := [2]f32{200, 200} * scale
	card_rect := [4]f32{card_origin.x, card_origin.y, card_origin.x + card_size.x, card_origin.y + card_size.y}
	render.push({rect = card_rect, color = colors.card, border_color = colors.line, border_width = 1 * scale, corner_radius = 8 * scale, clip = full_clip})

	mouse := app.mouse_points * pixels_per_point
	hover_size := 24 * scale
	hover_rect := [4]f32{mouse.x - hover_size, mouse.y - hover_size, mouse.x + hover_size, mouse.y + hover_size}
	render.push({rect = hover_rect, color = colors.hover, corner_radius = hover_size, clip = full_clip})
	app.frame_count += 1
	is_capture_frame := app.capture_path != "" && app.frame_count == 3
	if is_capture_frame do render.request_capture(app.capture_path)
	render.end_frame()
	if is_capture_frame do platform.quit()

	return app.capture_path != ""
}

log_frame_time :: proc() {
	if !app.is_logging_frames do return

	append(&app.frame_times, time.tick_now())

	if len(app.frame_times) < 121 do return

	longest: time.Duration
	for index in 1 ..< len(app.frame_times) {
		longest = max(longest, time.tick_diff(app.frame_times[index - 1], app.frame_times[index]))
	}
	total := time.tick_diff(app.frame_times[0], app.frame_times[len(app.frame_times) - 1])
	fmt.printfln("frames: 120 in %v, longest gap %v", total, longest)
	clear(&app.frame_times)
}
