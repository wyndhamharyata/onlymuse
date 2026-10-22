package app

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:console"
import "om:apple"
import "om:font"
import "om:helper"
import "om:icon"
import "om:image"
import "om:platform"
import "om:render"
import "om:store"
import "om:ui"
import "om:youtube"

// The zoom of the whole window, as in a browser.
zoom_steps := [?]f32{0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2}
BENCH_POINTS_PER_FRAME :: 30
// The first frames open the window and load fonts, so the bench leaves them out.
BENCH_SKIPPED_FRAME_COUNT :: 10

Panel :: enum {
	None,
	Lyrics,
	Up_Next,
}

app: struct {
	window:            ^platform.Window,
	zoom:              f32,
	// The playing song's cover's colour, or system_accent when it has none to give.
	accent:            [4]f32,
	// The accent chosen in System Settings, as the helper reports it.
	system_accent:     [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	// The tab the panel opens on.
	last_panel:        Panel,
	is_sign_in_needed: bool,
	// OM_TYPE: text typed into the focused field a second in, for the tests.
	test_typing:       string,
	started_at:        time.Tick,
	is_sign_in_open:   bool,
	last_frame:        time.Tick,
	// OM_CAPTURE saves a frame to this file and quits, for the development tests. OM_CAPTURE_SECONDS waits first.
	capture_path:      string,
	capture_time:      time.Tick,
	frame_count:       int,
	is_bench:          bool,
	// OM_FRAMES=1 shows how long each frame took to build.
	is_showing_frames: bool,
	bench_frame_count: int,
	bench_direction:   f32,
	build_durations:   [dynamic]time.Duration,
	frame_starts:      [dynamic]time.Tick,
}

// Each frame's temp memory, of which a long page takes more than the 256 KB build.sh gives each thread.
MAIN_TEMP_BYTES :: 4 * 1024 * 1024

main :: proc() {
	runtime.default_temp_allocator_init(&runtime.global_default_temp_allocator_data, MAIN_TEMP_BYTES, context.allocator)
	app.zoom = 1
	app.accent = DEFAULT_ACCENT
	app.system_accent = DEFAULT_ACCENT
	app.panel = .Lyrics
	app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	app.bench_frame_count = strconv.parse_int(os.get_env("OM_BENCH_FRAMES", context.temp_allocator)) or_else 1200
	app.bench_direction = 1
	app.is_showing_frames = os.get_env("OM_FRAMES", context.temp_allocator) == "1"
	capture_seconds := strconv.parse_f64(os.get_env("OM_CAPTURE_SECONDS", context.temp_allocator)) or_else 0
	app.capture_time = time.tick_add(time.tick_now(), time.Duration(capture_seconds * f64(time.Second)))

	store.start()
	apple.start()
	youtube.start()
	start_queue()
	start_navigation()
	start_saved_window_state()
	start_lyrics()
	start_search_field()
	start_play_log()
	start_song_menu()
	start_palette()
	start_shuffle_rules()
	if term := os.get_env("OM_PALETTE", context.temp_allocator); term != "" do open_palette_for_test(term)
	app.test_typing = os.get_env("OM_TYPE", context.allocator)
	app.started_at = time.tick_now()

	// A test or bench run opens behind the other windows and leaves Music.app as it is when it quits.
	is_background := app.capture_path != "" || app.is_bench || os.get_env("OM_BACKGROUND", context.temp_allocator) == "1"
	helper.start(is_background)

	// The bench measures the screen's own frames, so its window shows in front.
	// OM_WINDOW=<width>x<height> opens the window at that size in points, for the tests.
	window_size := [2]f32{1200, 800}
	if size_text := os.get_env("OM_WINDOW", context.temp_allocator); size_text != "" {
		if width_text, _, height_text := strings.partition(size_text, "x"); height_text != "" {
			window_size = {f32(strconv.parse_f64(width_text) or_else 1200), f32(strconv.parse_f64(height_text) or_else 800)}
		}
	}
	app.window = platform.open_window("onlymuse", window_size, {MIN_WINDOW_WIDTH_POINTS, MIN_WINDOW_HEIGHT_POINTS}, draw_frame, is_background && !app.is_bench)
	// A zoom saved on a larger screen steps down until its smallest window fits on this one.
	for app.zoom > zoom_steps[0] && !does_zoom_fit(app.zoom) do app.zoom = zoom_steps[max(find_zoom_step() - 1, 0)]
	apply_min_window_size()
	render.start(app.window.device, app.window.layer)
	font.start()
	icon.start()
	image.start()
	app.last_frame = time.tick_now()
	platform.run()
}

apply_helper_messages :: proc() {
	for message in helper.take_messages() {
		helper.apply(&app.now_playing, message)

		switch message.type {
		case "accent":
			app.system_accent = to_color_from_hex(message.color)
		case "tokens":
			apple.set_tokens(message.developer_token, message.user_token)
			app.is_sign_in_needed = false
		case "signInNeeded":
			app.is_sign_in_needed = true
		case "youtubeCookie":
			apply_youtube_cookie(message)
		case "error":
			// Music.app has no current track while stopped, and the helper's next post says so.
			if !strings.contains(message.text, "get current track") do console.add("Helper", "%s", message.text)
		case "trackInfo":
			apply_track_info(message)
		case "setFavoriteResult":
			apply_favourite_answer(message)
		case "playSongResult", "setNextResult":
			apply_queue_answer(message.request_id, message.persistent_id)
		case "nowPlaying":
			apply_queue_now_playing()
		}
	}
}

apply_keys :: proc() {
	for event in platform.list_events() {
		key, ok := event.(platform.Key_Press)
		if !ok || .Command not_in key.modifiers do continue

		apply_lead_key(key)

		switch key.characters {
		case "=", "+":
			set_zoom(zoom_steps[min(find_zoom_step() + 1, len(zoom_steps) - 1)])
		case "-":
			set_zoom(zoom_steps[max(find_zoom_step() - 1, 0)])
		case "0":
			set_zoom(1)
		case "q":
			platform.quit()
		case "k":
			toggle_palette()
		case "l":
			if song, persistent_id, is_song := find_playing_song(); is_song do toggle_favourite(song, persistent_id)
		}
	}
}

// Opens the panel on the tab it last showed, or closes it.
toggle_side_panel :: proc() {
	set_panel(.None if app.panel != .None else app.last_panel)
}

set_panel :: proc(panel: Panel) {
	app.panel = panel
	if panel != .None do app.last_panel = panel
	saved := [Panel]string{.None = "null", .Lyrics = `"lyrics"`, .Up_Next = `"queue"`}
	store.save_state("panel", saved[panel])
}

// The panel and the zoom of the last run.
start_saved_window_state :: proc() {
	app.last_panel = .Up_Next

	if panel, ok := store.find_state("panel", context.temp_allocator); ok {
		switch panel {
		case `"lyrics"`:
			app.panel = .Lyrics
			app.last_panel = .Lyrics
		case `"queue"`:
			app.panel = .Up_Next
		case "null":
			app.panel = .None
		}
	}

	if zoom, ok := store.find_state("zoom", context.temp_allocator); ok {
		value, is_number := strconv.parse_f32(zoom)
		for step in zoom_steps do if is_number && abs(step - value) < 0.001 do app.zoom = step
	}
}

// The step nearest the zoom.
find_zoom_step :: proc() -> int {
	nearest := 0
	for step, index in zoom_steps do if abs(step - app.zoom) < abs(zoom_steps[nearest] - app.zoom) do nearest = index

	return nearest
}

// Zooming in stops at the step whose smallest window no longer fits on the screen.
set_zoom :: proc(zoom: f32) {
	if zoom > app.zoom && !does_zoom_fit(zoom) do return

	app.zoom = zoom
	store.save_state("zoom", fmt.tprintf("%g", zoom))
	apply_min_window_size()
}

// The sidebar, a page and the side panel fit side by side in the smallest window at any zoom, because the
// smallest window grows with the zoom.
apply_min_window_size :: proc() {
	platform.set_min_size(to_min_window_size(app.zoom))
}

does_zoom_fit :: proc(zoom: f32) -> bool {
	min_size := to_min_window_size(zoom)
	screen := platform.screen_size_points()

	return min_size.x <= screen.x && min_size.y <= screen.y
}

to_min_window_size :: proc(zoom: f32) -> [2]f32 {
	return {MIN_WINDOW_WIDTH_POINTS, MIN_WINDOW_HEIGHT_POINTS} * zoom
}

draw_frame :: proc() -> bool {
	free_all(context.temp_allocator)
	free_retired_memory()
	start := time.tick_now()
	dt_seconds := f32(time.duration_seconds(time.tick_diff(app.last_frame, start)))
	app.last_frame = start
	if app.is_bench do append(&app.frame_starts, start)
	// Before the frame reads its events, so the typed keys are among them.
	if app.test_typing != "" && time.duration_seconds(time.tick_since(app.started_at)) > 1 {
		has_context := platform.type_for_test(app.test_typing)
		fmt.eprintfln("typed %q, input context: %v", app.test_typing, has_context)
		app.test_typing = ""
	}
	apply_helper_messages()
	update_queue()
	update_play_log()
	apply_write_results()
	apply_text_events()
	apply_keys()

	window := app.window
	size_pixels := window.size_points * window.pixels_per_point

	render.begin_frame(size_pixels)
	font.begin_frame()
	image.begin_frame()
	icon.begin_frame()
	ui.begin_frame(window.size_points, window.pixels_per_point, app.zoom, dt_seconds)
	update_accent(dt_seconds)

	root := ui.current_parent()
	root.style.axis = .Y
	root.style.background = colors.window
	is_lyrics_moving := false

	top := ui.box("top", {width = ui.fill(), height = ui.fill(), axis = .X})

	if ui.scope(top) {
		build_sidebar()
		build_page_area()
		is_lyrics_moving = build_panel()
	}

	build_player_bar()
	build_song_menu()
	build_drag_ghost()
	build_palette()
	build_shuffle_rules()
	build_toast()
	if app.is_sign_in_needed do build_sign_in_card()
	build_frame_time()
	ui.end_frame()
	finish_text_fields()

	// A scroll that has come to rest is saved, once.
	if is_scroll_changed && !ui.is_animating() {
		is_scroll_changed = false
		save_navigation()
	}

	app.frame_count += 1

	is_capture_frame := app.capture_path != "" && app.frame_count >= 3 && time.tick_diff(app.capture_time, start) >= 0
	if is_capture_frame do render.request_capture(app.capture_path)
	// Only the bench reads more than the last duration.
	if !app.is_bench do clear(&app.build_durations)
	append(&app.build_durations, time.tick_since(start))
	render.end_frame(window.drawable)
	if is_capture_frame do platform.quit()
	if app.is_bench && app.frame_count == app.bench_frame_count do finish_bench()

	return app.capture_path != "" || app.is_bench || ui.is_animating() || font.is_redraw_needed() || icon.is_redraw_needed() || image.is_animating() || is_lyrics_moving
}

SIGN_IN_CARD_POINTS :: 380

// onlymuse reads Apple Music with the sign-in of music.apple.com, which the helper keeps.
build_sign_in_card :: proc() {
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	// It takes every click, so nothing behind it opens.
	cover := ui.box("sign in cover", {width = ui.fill(), height = ui.fill(), background = to_color(0x000000a0), position = {0, 0}, flags = {.Floating, .Clickable}})

	if ui.scope(cover) {
		card := ui.box("card", {
			width         = ui.points(SIGN_IN_CARD_POINTS),
			height        = ui.fit_children(),
			axis          = .Y,
			gap           = 12,
			padding       = {24, 24, 24, 24},
			corner_radius = 14,
			background    = colors.card,
			border_width  = 1,
			border_color  = colors.line,
			position      = {(window_size.x - SIGN_IN_CARD_POINTS) / 2, window_size.y / 2 - 110},
			flags         = {.Floating},
		})

		if ui.scope(card) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 18, font_weight = .Bold}, "Sign in to Apple Music")
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, flags = {.Wrap_Text}}, "onlymuse reads Apple Music with the sign-in of music.apple.com. Apple's own sign-in page opens in a window of its own.")

			label := "Open the sign-in window again" if app.is_sign_in_open else "Sign In"
			if action_button(label, "person.crop.circle", true) {
				app.is_sign_in_open = true
				helper.send(`{"type":"signIn"}`)
			}
		}
	}
}

build_frame_time :: proc() {
	count := len(app.build_durations)
	if count == 0 || !app.is_showing_frames do return

	last := time.duration_milliseconds(app.build_durations[count - 1])
	root := ui.current_parent()
	ui.box("", {
		width      = ui.points(110),
		height     = ui.points(20),
		position   = {root.style.width.value - 120, 8},
		text_align = .End,
		text_color = colors.faint,
		font_size  = 11,
		flags      = {.Floating},
	}, fmt.tprintf("frame %.2f ms", last))
}

run_bench_scroll :: proc(list: ^ui.Box) {
	if !app.is_bench do return

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
	ready, total := image.count()
	fmt.printfln("covers on the GPU %d, known %d", ready, total)
	fmt.printfln("gap between frames ms: p50 %.2f p99 %.2f max %.2f", to_ms(gaps[:], 0.5), to_ms(gaps[:], 0.99), to_ms(gaps[:], 1))
	platform.quit()
}
