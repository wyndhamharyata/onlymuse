// Opens the window and builds each frame from the packages below. The sidebar, the Console page, zoom and
// the bench live here too.
package app

import "base:runtime"
import "core:fmt"
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
import "om:app/youtube_lists"
import "om:app/youtube_pages"
import "om:apple"
import "om:console"
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
	runtime.default_temp_allocator_init(&runtime.global_default_temp_allocator_data, MAIN_TEMP_BYTES, context.allocator)
	core.app.zoom = 1
	core.app.accent = kit.DEFAULT_ACCENT
	core.app.system_accent = kit.DEFAULT_ACCENT
	core.app.panel = .Lyrics
	core.app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	core.app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	core.app.bench_frame_count = strconv.parse_int(os.get_env("OM_BENCH_FRAMES", context.temp_allocator)) or_else 1200
	core.app.bench_direction = 1
	core.app.is_showing_frames = os.get_env("OM_FRAMES", context.temp_allocator) == "1"
	capture_seconds := strconv.parse_f64(os.get_env("OM_CAPTURE_SECONDS", context.temp_allocator)) or_else 0
	core.app.capture_time = time.tick_add(time.tick_now(), time.Duration(capture_seconds * f64(time.Second)))

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
	if term := os.get_env("OM_PALETTE", context.temp_allocator); term != "" do palette.open_palette_for_test(term)
	core.app.test_typing = os.get_env("OM_TYPE", context.allocator)
	core.app.started_at = time.tick_now()

	// A test or bench run opens behind the other windows and leaves Music.app as it is when it quits.
	is_background := core.app.capture_path != "" || core.app.is_bench || os.get_env("OM_BACKGROUND", context.temp_allocator) == "1"
	helper.start(is_background)

	// The bench measures the screen's own frames, so its window shows in front.
	// OM_WINDOW=<width>x<height> opens the window at that size in points, for the tests.
	window_size := [2]f32{1200, 800}
	if size_text := os.get_env("OM_WINDOW", context.temp_allocator); size_text != "" {
		if width_text, _, height_text := strings.partition(size_text, "x"); height_text != "" {
			window_size = {f32(strconv.parse_f64(width_text) or_else 1200), f32(strconv.parse_f64(height_text) or_else 800)}
		}
	}
	core.app.window = platform.open_window("onlymuse", window_size, {kit.MIN_WINDOW_WIDTH_POINTS, kit.MIN_WINDOW_HEIGHT_POINTS}, draw_frame, is_background && !core.app.is_bench)
	// A zoom saved on a larger screen steps down until its smallest window fits on this one.
	for core.app.zoom > zoom_steps[0] && !does_zoom_fit(core.app.zoom) do core.app.zoom = zoom_steps[max(find_zoom_step() - 1, 0)]
	apply_min_window_size()
	render.start(core.app.window.device, core.app.window.layer)
	font.start()
	icon.start()
	image.start()
	core.app.last_frame = time.tick_now()
	platform.run()
}

apply_helper_messages :: proc() {
	for message in helper.take_messages() {
		helper.apply(&core.app.now_playing, message)

		switch message.type {
		case "accent":
			core.app.system_accent = kit.to_color_from_hex(message.color)
		case "tokens":
			apple.set_tokens(message.developer_token, message.user_token)
			core.app.is_sign_in_needed = false
		case "signInNeeded":
			core.app.is_sign_in_needed = true
		case "youtubeCookie":
			youtube_pages.apply_youtube_cookie(message)
		case "error":
			// Music.app has no current track while stopped, and the helper's next post says so.
			if !strings.contains(message.text, "get current track") do console.add("Helper", "%s", message.text)
		case "trackInfo":
			playback.apply_track_info(message)
		case "setFavoriteResult":
			playback.apply_favourite_answer(message)
		case "playSongResult", "setNextResult":
			playback.apply_queue_answer(message.request_id, message.persistent_id)
		case "nowPlaying":
			playback.apply_queue_now_playing()
		}
	}
}

apply_keys :: proc() {
	for event in platform.list_events() {
		key, ok := event.(platform.Key_Press)
		if !ok || .Command not_in key.modifiers do continue

		player.apply_lead_key(key)

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
			palette.toggle_palette()
		case "l":
			if song, persistent_id, is_song := playback.find_playing_song(); is_song do playback.toggle_favourite(song, persistent_id)
		}
	}
}

draw_frame :: proc() -> bool {
	// Temp memory lives for one frame. The last frame has been drawn, so its temp memory goes now.
	free_all(context.temp_allocator)
	core.free_retired_memory()
	playback.free_retired_songs()
	youtube_lists.free_unused_youtube_lists()
	start := time.tick_now()
	dt_seconds := f32(time.duration_seconds(time.tick_diff(core.app.last_frame, start)))
	core.app.last_frame = start
	if core.app.is_bench do append(&core.app.frame_starts, start)
	// Before the frame reads its events, so the typed keys are among them.
	if core.app.test_typing != "" && time.duration_seconds(time.tick_since(core.app.started_at)) > 1 {
		has_context := platform.type_for_test(core.app.test_typing)
		fmt.eprintfln("typed %q, input context: %v", core.app.test_typing, has_context)
		core.app.test_typing = ""
	}
	apply_helper_messages()
	playback.update_queue()
	playback.update_play_log()
	menus.apply_write_results()
	kit.apply_text_events()
	apply_keys()

	window := core.app.window
	size_pixels := window.size_points * window.pixels_per_point

	render.begin_frame(size_pixels)
	font.begin_frame()
	image.begin_frame()
	icon.begin_frame()
	ui.begin_frame(window.size_points, window.pixels_per_point, core.app.zoom, dt_seconds)
	kit.update_accent(dt_seconds, player.find_player_artwork_source())

	root := ui.current_parent()
	root.style.axis = .Y
	root.style.background = kit.colors.window
	is_lyrics_moving := false

	top := ui.box("top", {width = ui.fill(), height = ui.fill(), axis = .X})

	if ui.scope(top) {
		build_sidebar()
		build_page_area()
		is_lyrics_moving = player.build_panel()
	}

	player.build_player_bar()
	menus.build_song_menu()
	menus.build_drag_ghost()
	palette.build_palette()
	playback.build_shuffle_rules()
	kit.build_toast()
	if core.app.is_sign_in_needed do build_sign_in_card()
	build_frame_time()
	ui.end_frame()
	kit.finish_text_fields()

	// A scroll that has come to rest is saved, once.
	if core.is_scroll_changed && !ui.is_animating() {
		core.is_scroll_changed = false
		core.save_navigation()
	}

	core.app.frame_count += 1

	is_capture_frame := core.app.capture_path != "" && core.app.frame_count >= 3 && time.tick_diff(core.app.capture_time, start) >= 0
	if is_capture_frame do render.request_capture(core.app.capture_path)
	// Only the bench reads more than the last duration.
	if !core.app.is_bench do clear(&core.app.build_durations)
	append(&core.app.build_durations, time.tick_since(start))
	render.end_frame(window.drawable)
	if is_capture_frame do platform.quit()
	if core.app.is_bench && core.app.frame_count == core.app.bench_frame_count do finish_bench()

	return core.app.capture_path != "" || core.app.is_bench || ui.is_animating() || font.is_redraw_needed() || icon.is_redraw_needed() || image.is_animating() || is_lyrics_moving
}

SIGN_IN_CARD_POINTS :: 380

// onlymuse reads Apple Music with the sign-in of music.apple.com, which the helper keeps.
build_sign_in_card :: proc() {
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	// It takes every click, so nothing behind it opens.
	cover := ui.box("sign in cover", {width = ui.fill(), height = ui.fill(), background = kit.to_color(0x000000a0), position = {0, 0}, flags = {.Floating, .Clickable}})

	if ui.scope(cover) {
		card := ui.box("card", {
			width         = ui.points(SIGN_IN_CARD_POINTS),
			height        = ui.fit_children(),
			axis          = .Y,
			gap           = 12,
			padding       = {24, 24, 24, 24},
			corner_radius = 14,
			background    = kit.colors.card,
			border_width  = 1,
			border_color  = kit.colors.line,
			position      = {(window_size.x - SIGN_IN_CARD_POINTS) / 2, window_size.y / 2 - 110},
			flags         = {.Floating},
		})

		if ui.scope(card) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 18, font_weight = .Bold}, "Sign in to Apple Music")
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.dim, flags = {.Wrap_Text}}, "onlymuse reads Apple Music with the sign-in of music.apple.com. Apple's own sign-in page opens in a window of its own.")

			label := "Open the sign-in window again" if core.app.is_sign_in_open else "Sign In"
			if kit.action_button(label, "person.crop.circle", true) {
				core.app.is_sign_in_open = true
				helper.send(`{"type":"signIn"}`)
			}
		}
	}
}
