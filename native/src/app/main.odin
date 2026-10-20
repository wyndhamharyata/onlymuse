package app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"
import "om:font"
import "om:platform"
import "om:render"

to_color :: proc "contextless" (hex: u32) -> [4]f32 {
	return {f32((hex >> 24) & 0xff) / 255, f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255}
}

colors := struct {
	window, sidebar, card, line, hover, text, dim: [4]f32,
} {
	window  = to_color(0x1b1b1ed9),
	sidebar = to_color(0xffffff08),
	card    = to_color(0x2a2a2fff),
	line    = to_color(0x2e2e33ff),
	hover   = to_color(0xffffff12),
	text    = to_color(0xf2f2f4ff),
	dim     = to_color(0xacacb4ff),
}

MIN_ZOOM :: 0.5
MAX_ZOOM :: 3.0
ZOOM_STEP :: 0.1
SIDEBAR_WIDTH_POINTS :: 228
ROW_HEIGHT_POINTS :: 44
ROW_COUNT :: 2000
// A mouse wheel reports lines.
POINTS_PER_LINE :: 40
BENCH_FRAME_COUNT :: 1200
BENCH_POINTS_PER_FRAME :: 30

sample_songs := [][2]string {
	{"soldier game", "ADO"},
	{"怪物", "YOASOBI"},
	{"残響散歌", "Aimer"},
	{"Lemon", "米津玄師"},
	{"Bling-Bang-Bang-Born", "Creepy Nuts"},
	{"群青", "YOASOBI"},
	{"花に亡霊", "ヨルシカ"},
	{"Oikaze", "Kenshi Yonezu"},
	{"踊り子", "Vaundy"},
	{"Pretender", "Official髭男dism"},
	{"Habit", "SEKAI NO OWARI"},
	{"KICK BACK", "米津玄師"},
}

app: struct {
	window:            ^platform.Window,
	zoom:              f32,
	mouse_points:      [2]f32,
	scroll_points:     f32,
	titles:            [ROW_COUNT]string,
	// OM_CAPTURE saves the third frame to this file and quits, for the development tests.
	capture_path:      string,
	frame_count:       int,
	is_bench:          bool,
	bench_direction:   f32,
	frame_durations:   [dynamic]time.Duration,
	build_durations:   [dynamic]time.Duration,
	buffer_waits:      [dynamic]time.Duration,
	frame_starts:      [dynamic]time.Tick,
}

main :: proc() {
	app.zoom = 1
	app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	app.bench_direction = 1

	for &title, index in app.titles {
		song := sample_songs[index % len(sample_songs)]
		title = fmt.aprintf("%d. %s (%d)", index + 1, song[0], index / len(sample_songs) + 1)
	}

	app.window = platform.open_window("onlymuse", {1200, 800}, draw_frame)
	render.start(app.window.device, app.window.layer)
	font.start()
	platform.run()
}

apply_events :: proc() {
	for event in platform.list_events() {
		#partial switch e in event {
		case platform.Mouse_Move:
			app.mouse_points = e.position
		case platform.Scroll:
			delta := e.delta.y if e.is_precise else e.delta.y * POINTS_PER_LINE
			app.scroll_points -= delta / app.zoom
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
	start := time.tick_now()
	append(&app.frame_starts, start)
	apply_events()

	if app.is_bench do app.scroll_points += BENCH_POINTS_PER_FRAME * app.bench_direction

	window := app.window
	pixels_per_point := window.pixels_per_point
	size_pixels := window.size_points * pixels_per_point
	// Layout works in points times zoom, and draws in pixels.
	scale := pixels_per_point * app.zoom
	full_clip := [4]f32{0, 0, size_pixels.x, size_pixels.y}
	sidebar_width := SIDEBAR_WIDTH_POINTS * scale

	render.begin_frame(size_pixels)
	font.begin_frame()
	render.push({rect = {0, 0, size_pixels.x, size_pixels.y}, color = colors.window, clip = full_clip})
	render.push({rect = {0, 0, sidebar_width, size_pixels.y}, color = colors.sidebar, clip = full_clip})

	sidebar_font := font.system_font(.Semibold, 13 * scale)
	sidebar_title := font.shape("onlymuse native", sidebar_font)
	font.draw(sidebar_title, {20 * scale, 52 * scale}, colors.text, full_clip)

	draw_rows(sidebar_width, size_pixels, scale)
	draw_frame_time(size_pixels, scale, full_clip)

	app.frame_count += 1
	is_capture_frame := app.capture_path != "" && app.frame_count == 3
	if is_capture_frame do render.request_capture(app.capture_path)
	append(&app.build_durations, time.tick_since(start))
	render.end_frame(window.drawable)
	append(&app.buffer_waits, render.last_buffer_wait())
	append(&app.frame_durations, time.tick_since(start))
	if is_capture_frame do platform.quit()
	if app.is_bench && app.frame_count == BENCH_FRAME_COUNT do finish_bench()

	return app.capture_path != "" || app.is_bench || font.is_redraw_needed()
}

draw_rows :: proc(left: f32, size_pixels: [2]f32, scale: f32) {
	row_height := ROW_HEIGHT_POINTS * scale
	top := 52 * scale
	list_clip := [4]f32{left, top, size_pixels.x, size_pixels.y}
	max_scroll := max(0, ROW_COUNT * ROW_HEIGHT_POINTS - (size_pixels.y - top) / scale)

	if app.is_bench && (app.scroll_points >= max_scroll || app.scroll_points <= 0) do app.bench_direction *= -1

	app.scroll_points = clamp(app.scroll_points, 0, max_scroll)
	scroll := app.scroll_points * scale
	first_row := int(scroll / row_height)
	last_row := min(ROW_COUNT - 1, int((scroll + size_pixels.y - top) / row_height))
	title_font := font.system_font(.Medium, 13 * scale)
	artist_font := font.system_font(.Regular, 12 * scale)
	mouse := app.mouse_points * app.window.pixels_per_point
	padding := 30 * scale

	for row in first_row ..= last_row {
		row_top := top + f32(row) * row_height - scroll
		row_rect := [4]f32{left + padding - 10 * scale, row_top, size_pixels.x - padding + 10 * scale, row_top + row_height}
		is_hovered := mouse.x >= row_rect.x && mouse.x < row_rect.z && mouse.y >= row_rect.y && mouse.y < row_rect.w

		if is_hovered do render.push({rect = row_rect, color = colors.hover, corner_radius = 6 * scale, clip = list_clip})

		song := sample_songs[row % len(sample_songs)]
		cover_size := 32 * scale
		cover_top := row_top + (row_height - cover_size) / 2
		render.push({rect = {left + padding, cover_top, left + padding + cover_size, cover_top + cover_size}, color = colors.card, corner_radius = 4 * scale, clip = list_clip})

		text_left := left + padding + cover_size + 12 * scale
		title := font.shape(app.titles[row], title_font)
		artist := font.shape(song[1], artist_font)
		font.draw(title, {text_left, row_top + 4 * scale}, colors.text, list_clip)
		font.draw(artist, {text_left, row_top + 22 * scale}, colors.dim, list_clip)
		render.push({rect = {text_left, row_top + row_height - scale, row_rect.z, row_top + row_height}, color = colors.line, clip = list_clip})
	}
}

draw_frame_time :: proc(size_pixels: [2]f32, scale: f32, clip: [4]f32) {
	count := len(app.frame_durations)
	if count == 0 do return

	last := app.frame_durations[count - 1]
	text := fmt.tprintf("frame %.2f ms", time.duration_milliseconds(last))
	label_font := font.system_font(.Regular, 11 * scale)
	shaped := font.shape(text, label_font)
	font.draw(shaped, {size_pixels.x - shaped.size.x - 16 * scale, 16 * scale}, colors.dim, clip)
}

// The first frames open the window and load fonts, so they are left out.
BENCH_SKIPPED_FRAME_COUNT :: 10

finish_bench :: proc() {
	skipped := BENCH_SKIPPED_FRAME_COUNT
	remove_range(&app.frame_durations, 0, skipped)
	remove_range(&app.build_durations, 0, skipped)
	remove_range(&app.frame_starts, 0, skipped)
	remove_range(&app.buffer_waits, 0, skipped)
	durations := app.frame_durations[:]
	slice.sort(durations)
	builds := app.build_durations[:]
	slice.sort(builds)
	gaps: [dynamic]time.Duration
	for index in 1 ..< len(app.frame_starts) do append(&gaps, time.tick_diff(app.frame_starts[index - 1], app.frame_starts[index]))
	slice.sort(gaps[:])

	to_ms :: proc(values: []time.Duration, fraction: f64) -> f64 {
		return time.duration_milliseconds(values[int(math.floor(f64(len(values) - 1) * fraction))])
	}
	fmt.printfln("build per frame ms: p50 %.2f p99 %.2f max %.2f", to_ms(builds, 0.5), to_ms(builds, 0.99), to_ms(builds, 1))
	fmt.printfln("build and submit per frame ms: p50 %.2f p99 %.2f max %.2f", to_ms(durations, 0.5), to_ms(durations, 0.99), to_ms(durations, 1))
	fmt.printfln("gap between frames ms: p50 %.2f p99 %.2f max %.2f", to_ms(gaps[:], 0.5), to_ms(gaps[:], 0.99), to_ms(gaps[:], 1))
	slice.sort(app.buffer_waits[:])
	fmt.printfln("buffer wait ms: p50 %.2f p99 %.2f max %.2f", to_ms(app.buffer_waits[:], 0.5), to_ms(app.buffer_waits[:], 0.99), to_ms(app.buffer_waits[:], 1))
	platform.quit()
}
