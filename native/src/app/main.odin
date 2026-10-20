package app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import "om:font"
import "om:platform"
import "om:render"
import "om:ui"

to_color :: proc "contextless" (hex: u32) -> [4]f32 {
	return {f32((hex >> 24) & 0xff) / 255, f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255}
}

// The colours of the gpuix app's src/theme.ts.
colors := struct {
	window, sidebar, panel, card, line, hover, pressed, text, dim, accent, accent_tint: [4]f32,
} {
	window      = to_color(0x1b1b1ed9),
	sidebar     = to_color(0xffffff08),
	panel       = to_color(0xffffff06),
	card        = to_color(0x2a2a2fff),
	line        = to_color(0x2e2e33ff),
	hover       = to_color(0xffffff12),
	pressed     = to_color(0xffffff1a),
	text        = to_color(0xf2f2f4ff),
	dim         = to_color(0xacacb4ff),
	accent      = to_color(0xf7821bff),
	// About 18% of the accent, as the selected rows in the design.
	accent_tint = to_color(0xf7821b2e),
}

MIN_ZOOM :: 0.5
MAX_ZOOM :: 3.0
ZOOM_STEP :: 0.1
SIDEBAR_WIDTH_POINTS :: 228
PANEL_WIDTH_POINTS :: 300
ROW_HEIGHT_POINTS :: 52
ROW_COUNT :: 2000
// Rows built past each edge of the list, so a fast scroll finds them ready.
EXTRA_ROW_COUNT :: 2
BENCH_FRAME_COUNT :: 1200
BENCH_POINTS_PER_FRAME :: 30
// The first frames open the window and load fonts, so the bench leaves them out.
BENCH_SKIPPED_FRAME_COUNT :: 10

pages := []string{"Home", "New", "Radio", "Recently Added", "Artists", "Albums", "Songs", "Playlists"}

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
	window:          ^platform.Window,
	zoom:            f32,
	titles:          [ROW_COUNT]string,
	page:            string,
	selected_row:    int,
	is_panel_open:   bool,
	last_frame:      time.Tick,
	// OM_CAPTURE saves a frame to this file and quits, for the development tests. OM_CAPTURE_SECONDS waits first.
	capture_path:    string,
	capture_time:    time.Tick,
	frame_count:     int,
	is_bench:        bool,
	bench_direction: f32,
	build_durations: [dynamic]time.Duration,
	frame_starts:    [dynamic]time.Tick,
}

main :: proc() {
	app.zoom = 1
	app.page = "Songs"
	app.selected_row = -1
	app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	capture_seconds := strconv.parse_f64(os.get_env("OM_CAPTURE_SECONDS", context.temp_allocator)) or_else 0
	app.capture_time = time.tick_add(time.tick_now(), time.Duration(capture_seconds * f64(time.Second)))
	app.bench_direction = 1

	for &title, index in app.titles {
		song := sample_songs[index % len(sample_songs)]
		title = fmt.aprintf("%d. %s (%d)", index + 1, song[0], index / len(sample_songs) + 1)
	}

	app.window = platform.open_window("onlymuse", {1200, 800}, draw_frame)
	render.start(app.window.device, app.window.layer)
	font.start()
	app.last_frame = time.tick_now()
	platform.run()
}

apply_keys :: proc() {
	for event in platform.list_events() {
		key, ok := event.(platform.Key_Press)
		if !ok || .Command not_in key.modifiers do continue

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
}

draw_frame :: proc() -> bool {
	free_all(context.temp_allocator)
	start := time.tick_now()
	dt_seconds := f32(time.duration_seconds(time.tick_diff(app.last_frame, start)))
	app.last_frame = start
	append(&app.frame_starts, start)
	apply_keys()

	window := app.window
	size_pixels := window.size_points * window.pixels_per_point

	render.begin_frame(size_pixels)
	font.begin_frame()
	ui.begin_frame(window.size_points, window.pixels_per_point, app.zoom, dt_seconds)

	root := ui.current_parent()
	root.style.axis = .X
	root.style.background = colors.window

	build_sidebar()
	build_main()
	build_panel()
	build_frame_time()

	ui.end_frame()

	app.frame_count += 1
	is_capture_frame := app.capture_path != "" && app.frame_count >= 3 && time.tick_diff(app.capture_time, start) >= 0
	if is_capture_frame do render.request_capture(app.capture_path)
	append(&app.build_durations, time.tick_since(start))
	render.end_frame(window.drawable)
	if is_capture_frame do platform.quit()
	if app.is_bench && app.frame_count == BENCH_FRAME_COUNT do finish_bench()

	return app.capture_path != "" || app.is_bench || ui.is_animating() || font.is_redraw_needed()
}

build_sidebar :: proc() {
	sidebar := ui.box("sidebar", {
		width      = ui.points(SIDEBAR_WIDTH_POINTS),
		height     = ui.fill(),
		axis       = .Y,
		padding    = {12, 52, 12, 12},
		gap        = 2,
		background = colors.sidebar,
	})

	if ui.scope(sidebar) {
		ui.box("", {width = ui.fill(), height = ui.points(24), padding = {10, 0, 10, 0}, text_color = colors.dim, font_size = 11, font_weight = .Semibold}, "Library")

		for page in pages {
			is_selected := page == app.page
			item := ui.box(page, {
				width            = ui.fill(),
				height           = ui.points(30),
				padding          = {10, 0, 10, 0},
				corner_radius    = 6,
				background       = colors.accent_tint if is_selected else {},
				hover_background = colors.accent_tint if is_selected else colors.hover,
				press_background = colors.pressed,
				text_color       = colors.accent if is_selected else colors.text,
				font_weight      = .Medium,
				flags            = {.Clickable},
			}, page)

			if ui.signal(item).is_clicked do app.page = page
		}
	}
}

build_main :: proc() {
	main_box := ui.box("main", {width = ui.fill(), height = ui.fill(), axis = .Y})

	if ui.scope(main_box) {
		header := ui.box("header", {width = ui.fill(), height = ui.points(64), axis = .X, align = .Center, padding = {30, 12, 30, 0}})

		if ui.scope(header) {
			ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.text, font_size = 24, font_weight = .Bold}, app.page)
			ui.box("", {width = ui.fill(), height = ui.points(1)})

			button := ui.box("panel button", {
				width            = ui.fit_text(),
				height           = ui.points(28),
				padding          = {14, 0, 14, 0},
				corner_radius    = 14,
				background       = colors.accent_tint if app.is_panel_open else colors.hover,
				hover_background = colors.pressed,
				press_background = colors.accent_tint,
				text_color       = colors.accent if app.is_panel_open else colors.text,
				font_weight      = .Medium,
				flags            = {.Clickable},
			}, "Up Next")

			if ui.signal(button).is_clicked do app.is_panel_open = !app.is_panel_open
		}

		build_list()
	}
}

build_list :: proc() {
	list := ui.box("list", {width = ui.fill(), height = ui.fill(), axis = .Y, padding = {20, 0, 20, 20}, flags = {.Scroll, .Clip}})

	if app.is_bench do run_bench_scroll(list)

	// The rows on screen, from the scroll and height the list had last frame.
	first_row := max(0, int(list.scroll / ROW_HEIGHT_POINTS) - EXTRA_ROW_COUNT)
	last_row := min(ROW_COUNT - 1, int((list.scroll + list.size.y) / ROW_HEIGHT_POINTS) + EXTRA_ROW_COUNT)

	if ui.scope(list) {
		ui.box("", {width = ui.fill(), height = ui.points(f32(first_row) * ROW_HEIGHT_POINTS)})

		for row in first_row ..= last_row do build_row(row)

		ui.box("", {width = ui.fill(), height = ui.points(f32(ROW_COUNT - 1 - last_row) * ROW_HEIGHT_POINTS)})
	}
}

build_row :: proc(row: int) {
	song := sample_songs[row % len(sample_songs)]
	is_selected := row == app.selected_row
	row_box := ui.box(fmt.tprintf("row %d", row), {
		width            = ui.fill(),
		height           = ui.points(ROW_HEIGHT_POINTS),
		axis             = .X,
		align            = .Center,
		padding          = {10, 0, 10, 0},
		gap              = 12,
		corner_radius    = 6,
		background       = colors.accent_tint if is_selected else {},
		hover_background = colors.accent_tint if is_selected else colors.hover,
		press_background = colors.pressed,
		flags            = {.Clickable},
	})

	if ui.signal(row_box).is_clicked do app.selected_row = row

	if ui.scope(row_box) {
		ui.box("", {width = ui.points(36), height = ui.points(36), corner_radius = 4, background = colors.card})

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_weight = .Medium}, app.titles[row])
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, font_size = 12}, song[1])
		}
	}
}

build_panel :: proc() {
	width := ui.animate("panel width", PANEL_WIDTH_POINTS if app.is_panel_open else 0)

	if width < 1 do return

	panel := ui.box("panel", {
		width      = ui.points(width),
		height     = ui.fill(),
		axis       = .Y,
		padding    = {16, 64, 16, 16},
		gap        = 4,
		background = colors.panel,
		fade       = 1 - width / PANEL_WIDTH_POINTS,
		flags      = {.Clip},
	})

	if ui.scope(panel) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 15, font_weight = .Bold, padding = {8, 0, 8, 8}}, "Up Next")

		for index in 0 ..< 12 {
			song := sample_songs[index]
			item := ui.box(fmt.tprintf("next %d", index), {
				width            = ui.points(PANEL_WIDTH_POINTS - 32),
				height           = ui.fit_children(),
				axis             = .Y,
				padding          = {8, 6, 8, 6},
				corner_radius    = 6,
				hover_background = colors.hover,
				flags            = {.Clickable},
			})

			if ui.scope(item) {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, flags = {.Wrap_Text}}, song[0])
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, font_size = 12}, song[1])
			}
		}
	}
}

build_frame_time :: proc() {
	count := len(app.build_durations)
	if count == 0 do return

	last := time.duration_milliseconds(app.build_durations[count - 1])
	root := ui.current_parent()
	label := fmt.tprintf("frame %.2f ms", last)
	ui.box("", {
		width      = ui.points(110),
		height     = ui.points(20),
		position   = {root.style.width.value - 120, 8},
		text_align = .End,
		text_color = colors.dim,
		font_size  = 11,
		flags      = {.Floating},
	}, label)
}

run_bench_scroll :: proc(list: ^ui.Box) {
	max_scroll := list.content_size.y - list.size.y

	if max_scroll <= 0 do return
	if list.scroll >= max_scroll || (list.scroll <= 0 && app.bench_direction < 0) do app.bench_direction *= -1

	ui.set_scroll(list, list.scroll + BENCH_POINTS_PER_FRAME * app.bench_direction)
}

finish_bench :: proc() {
	remove_range(&app.build_durations, 0, BENCH_SKIPPED_FRAME_COUNT)
	remove_range(&app.frame_starts, 0, BENCH_SKIPPED_FRAME_COUNT)

	builds := app.build_durations[:]
	slice.sort(builds)
	gaps: [dynamic]time.Duration
	for index in 1 ..< len(app.frame_starts) do append(&gaps, time.tick_diff(app.frame_starts[index - 1], app.frame_starts[index]))
	slice.sort(gaps[:])

	to_ms :: proc(values: []time.Duration, fraction: f64) -> f64 {
		return time.duration_milliseconds(values[int(math.floor(f64(len(values) - 1) * fraction))])
	}
	fmt.printfln("build per frame ms: p50 %.2f p99 %.2f max %.2f", to_ms(builds, 0.5), to_ms(builds, 0.99), to_ms(builds, 1))
	fmt.printfln("gap between frames ms: p50 %.2f p99 %.2f max %.2f", to_ms(gaps[:], 0.5), to_ms(gaps[:], 0.99), to_ms(gaps[:], 1))
	platform.quit()
}
