package app

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
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

// A long page needs more than the 256 KB that build.sh gives a thread.
MAIN_TEMP_BYTES :: 4 * 1024 * 1024

DEFAULT_BENCH_FRAME_COUNT :: 1200

DEFAULT_WINDOW_SIZE_POINTS :: [2]f32{1200, 800}

main :: proc() {
	runtime.default_temp_allocator_init(
		&runtime.global_default_temp_allocator_data,
		MAIN_TEMP_BYTES,
		context.allocator,
	)

	start_app_state()
	start_parts()

	is_background :=
		core.app.capture_path != "" ||
		core.app.is_bench ||
		os.get_env("OM_BACKGROUND", context.temp_allocator) == "1"
	helper.start(is_background)
	core.start_player_mode()
	open_main_window(is_background)

	render.start(core.app.window.device, core.app.window.layer)
	font.start()
	icon.start()
	image.start()

	core.app.last_frame = time.tick_now()
	platform.run()
}

start_app_state :: proc() {
	core.app.zoom = 1
	core.app.accent = kit.DEFAULT_ACCENT
	core.app.system_accent = kit.DEFAULT_ACCENT
	core.app.panel = .Lyrics

	core.app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	core.app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	core.app.bench_frame_count =
		strconv.parse_int(
			os.get_env("OM_BENCH_FRAMES", context.temp_allocator),
		) or_else DEFAULT_BENCH_FRAME_COUNT
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

start_parts :: proc() {
	store.start()
	matching.start_match_rule()
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

open_main_window :: proc(is_background: bool) {
	window_size := DEFAULT_WINDOW_SIZE_POINTS
	size_text := os.get_env("OM_WINDOW", context.temp_allocator)
	width_text, _, height_text := strings.partition(size_text, "x")

	if height_text != "" {
		window_size = {
			f32(strconv.parse_f64(width_text) or_else f64(DEFAULT_WINDOW_SIZE_POINTS.x)),
			f32(strconv.parse_f64(height_text) or_else f64(DEFAULT_WINDOW_SIZE_POINTS.y)),
		}
	}

	is_behind := is_background && !core.app.is_bench
	core.app.window = platform.open_window(
		"onlymuse",
		window_size,
		{kit.MIN_WINDOW_WIDTH_POINTS, kit.MIN_WINDOW_HEIGHT_POINTS},
		draw_frame,
		is_behind,
	)
	platform.set_background(kit.colors.window)
	platform.install_player_menu({
		is_driving = proc() -> bool {return core.app.drives_music_app},
		toggle = proc() {core.set_player_mode(!core.app.drives_music_app)},
	})

	for core.app.zoom > zoom_steps[0] && !is_zoom_fitting(core.app.zoom) {
		core.app.zoom = to_smaller_zoom(core.app.zoom)
	}

	set_min_window_size()
}

SIGN_IN_CARD_WIDTH_POINTS :: 380

SIGN_IN_CARD_HALF_HEIGHT_POINTS :: 110

build_sign_in_card :: proc() {
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
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
				width = ui.points(SIGN_IN_CARD_WIDTH_POINTS),
				height = ui.fit_children(),
				axis = .Y,
				gap = 12,
				padding = {24, 24, 24, 24},
				corner_radius = 14,
				background = kit.colors.card,
				border_width = 1,
				border_color = kit.colors.line,
				position = {
					(window_size.x - SIGN_IN_CARD_WIDTH_POINTS) / 2,
					window_size.y / 2 - SIGN_IN_CARD_HALF_HEIGHT_POINTS,
				},
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
				helper.send_sign_in()
			}
		}
	}
}
