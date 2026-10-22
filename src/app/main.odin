// Opens the window and builds each frame from the packages below. The sidebar, the Console page, zoom and
// the bench live here too.
package app

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:app/core"
import "om:app/kit"
import "om:app/menus"
import "om:app/palette"
import "om:app/playback"
import "om:app/player"
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

// Each frame's temp memory, of which a long page takes more than the 256 KB build.sh gives each thread.
MAIN_TEMP_BYTES :: 4 * 1024 * 1024

main :: proc() {
	runtime.default_temp_allocator_init(
		&runtime.global_default_temp_allocator_data,
		MAIN_TEMP_BYTES,
		context.allocator,
	)
	start_app_state()
	start_parts()

	// A test or bench run opens behind the other windows and leaves Music.app as it is when it quits.
	is_background :=
		core.app.capture_path != "" ||
		core.app.is_bench ||
		os.get_env("OM_BACKGROUND", context.temp_allocator) == "1"
	helper.start(is_background)
	open_main_window(is_background)

	render.start(core.app.window.device, core.app.window.layer)
	font.start()
	icon.start()
	image.start()
	core.app.last_frame = time.tick_now()
	platform.run()
}

// The app's first state, and what the OM_ settings of a test or bench ask for.
start_app_state :: proc() {
	core.app.zoom = 1
	core.app.accent = kit.DEFAULT_ACCENT
	core.app.system_accent = kit.DEFAULT_ACCENT
	core.app.panel = .Lyrics
	core.app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	core.app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	core.app.bench_frame_count =
		strconv.parse_int(os.get_env("OM_BENCH_FRAMES", context.temp_allocator)) or_else 1200
	core.app.bench_direction = 1
	core.app.is_showing_frames = os.get_env("OM_FRAMES", context.temp_allocator) == "1"
	capture_seconds :=
		strconv.parse_f64(os.get_env("OM_CAPTURE_SECONDS", context.temp_allocator)) or_else 0
	core.app.capture_time = time.tick_add(
		time.tick_now(),
		time.Duration(capture_seconds * f64(time.Second)),
	)
	core.app.test_typing = os.get_env("OM_TYPE", context.allocator)
	core.app.started_at = time.tick_now()
}

// In this order, as the queue, navigation and the rest read what the store saved.
start_parts :: proc() {
	store.start()
	apple.start()
	youtube.start()
	playback.start_queue()
	core.start_navigation()
	start_saved_window_state()
	player.start_lyrics()
	start_search_field()
	playback.start_play_log()
	menus.start_song_menu()
	palette.start_palette()
	playback.start_shuffle_rules()
	if term := os.get_env("OM_PALETTE", context.temp_allocator); term != "" {
		palette.open_palette_for_test(term)
	}
}

// OM_WINDOW=<width>x<height> opens the window at that size in points, for the tests.
open_main_window :: proc(is_background: bool) {
	window_size := [2]f32{1200, 800}
	if size_text := os.get_env("OM_WINDOW", context.temp_allocator); size_text != "" {
		if width_text, _, height_text := strings.partition(size_text, "x"); height_text != "" {
			window_size = {
				f32(strconv.parse_f64(width_text) or_else 1200),
				f32(strconv.parse_f64(height_text) or_else 800),
			}
		}
	}

	// The bench measures the screen's own frames, so its window shows in front.
	is_behind := is_background && !core.app.is_bench
	core.app.window = platform.open_window(
		"onlymuse",
		window_size,
		{kit.MIN_WINDOW_WIDTH_POINTS, kit.MIN_WINDOW_HEIGHT_POINTS},
		draw_frame,
		is_behind,
	)

	// A zoom saved on a larger screen steps down until its smallest window fits on this one.
	for core.app.zoom > zoom_steps[0] && !does_zoom_fit(core.app.zoom) {
		core.app.zoom = zoom_steps[max(find_zoom_step() - 1, 0)]
	}
	apply_min_window_size()
}

SIGN_IN_CARD_POINTS :: 380

// onlymuse reads Apple Music with the sign-in of music.apple.com, which the helper keeps.
build_sign_in_card :: proc() {
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	// It takes every click, so nothing behind it opens.
	cover := ui.box(
		"sign in cover",
		{
			width = ui.fill(),
			height = ui.fill(),
			background = kit.to_color(0x000000a0),
			position = {0, 0},
			flags = {.Floating, .Clickable},
		},
	)

	if ui.scope(cover) {
		card := ui.box(
			"card",
			{
				width = ui.points(SIGN_IN_CARD_POINTS),
				height = ui.fit_children(),
				axis = .Y,
				gap = 12,
				padding = {24, 24, 24, 24},
				corner_radius = 14,
				background = kit.colors.card,
				border_width = 1,
				border_color = kit.colors.line,
				position = {(window_size.x - SIGN_IN_CARD_POINTS) / 2, window_size.y / 2 - 110},
				flags = {.Floating},
			},
		)

		if ui.scope(card) {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.text,
					font_size = 18,
					font_weight = .Bold,
				},
				"Sign in to Apple Music",
			)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.dim,
					flags = {.Wrap_Text},
				},
				"onlymuse reads Apple Music with the sign-in of music.apple.com. Apple's own sign-in page opens in a window of its own.",
			)

			label := "Open the sign-in window again" if core.app.is_sign_in_open else "Sign In"
			if kit.action_button(label, "person.crop.circle", true) {
				core.app.is_sign_in_open = true
				helper.send(`{"type":"signIn"}`)
			}
		}
	}
}
