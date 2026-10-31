package app

import "core:fmt"
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
import "om:ui"

draw_frame :: proc() -> bool {
	start, frame_seconds := begin_frame()
	apply_input()

	window := core.app.window
	render.begin_frame(window.size_points * window.pixels_per_point)
	font.begin_frame()
	image.begin_frame()
	icon.begin_frame()
	ui.begin_frame(window.size_points, window.pixels_per_point, core.app.zoom, frame_seconds)
	kit.set_accent(frame_seconds, player.find_player_artwork_source())

	root := ui.current_parent()
	root.style.axis = .Y
	if core.app.capture_path != "" do root.style.background = kit.colors.window
	is_lyrics_moving := false

	top := ui.box("top", {width = ui.fill(), height = ui.fill(), axis = .X})

	if ui.scope(top) {
		build_sidebar()
		build_page_area()
		is_lyrics_moving = player.build_panel()
	}

	player.build_player_bar()
	menus.build_song_menu()
	menus.apply_drag_release()
	menus.build_drag_ghost()
	palette.build_palette()
	playback.build_shuffle_rules()
	kit.build_toast()
	if core.app.is_sign_in_needed do build_sign_in_card()
	build_frame_time()

	ui.end_frame()
	kit.finish_text_fields()

	finish_frame(start)

	return(
		core.app.capture_path != "" ||
		core.app.is_bench ||
		ui.is_animating() ||
		font.is_redraw_needed() ||
		icon.is_redraw_needed() ||
		image.is_animating() ||
		is_lyrics_moving \
	)
}

begin_frame :: proc() -> (start: time.Tick, frame_seconds: f32) {
	free_all(context.temp_allocator)
	core.free_retired_memory()
	playback.free_retired_songs()
	youtube_lists.free_unused_youtube_lists()

	start = time.tick_now()
	frame_seconds = f32(time.duration_seconds(time.tick_diff(core.app.last_frame, start)))
	core.app.last_frame = start
	if core.app.is_bench do append(&core.app.frame_starts, start)

	return start, frame_seconds
}

TEST_TYPING_DELAY_SECONDS :: 1

CAPTURE_MIN_FRAME_COUNT :: 3

apply_input :: proc() {
	seconds_since_start := time.duration_seconds(time.tick_since(core.app.started_at))
	is_typing_due := core.app.test_typing != "" && seconds_since_start > TEST_TYPING_DELAY_SECONDS

	if is_typing_due {
		has_context := platform.type_for_test(core.app.test_typing)
		fmt.eprintfln("typed %q, input context: %v", core.app.test_typing, has_context)
		core.app.test_typing = ""
	}

	apply_helper_messages()
	playback.update_queue()
	playback.apply_now_playing_to_play_log()
	menus.apply_write_results()
	kit.apply_text_events()
	apply_keys()
}

finish_frame :: proc(start: time.Tick) {
	is_scroll_at_rest := core.is_scroll_changed && !ui.is_animating()

	if is_scroll_at_rest {
		core.is_scroll_changed = false
		core.save_navigation()
	}

	core.app.frame_count += 1

	is_capture_frame :=
		core.app.capture_path != "" &&
		core.app.frame_count >= CAPTURE_MIN_FRAME_COUNT &&
		time.tick_diff(core.app.capture_time, start) >= 0
	if is_capture_frame do render.request_capture(core.app.capture_path)

	if !core.app.is_bench do clear(&core.app.build_durations)
	append(&core.app.build_durations, time.tick_since(start))

	is_bench_done := core.app.is_bench && core.app.frame_count == core.app.bench_frame_count

	render.end_frame(core.app.window.drawable)
	if is_capture_frame do platform.quit()
	if is_bench_done do finish_bench()
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
			// Music.app has no current song while nothing plays. The helper's next post says so.
			if !strings.contains(message.text, "get current track") {
				console.add("Helper", "%s", message.text)
			}
		case "songInfo":
			playback.apply_song_info(message)
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
		key, is_key := event.(platform.Key_Press)
		if !is_key || .Command not_in key.modifiers do continue

		player.apply_lead_key(key)

		switch key.characters {
		case "=", "+":
			set_zoom(zoom_steps[min(to_nearest_zoom_step(core.app.zoom) + 1, len(zoom_steps) - 1)])
		case "-":
			set_zoom(to_smaller_zoom(core.app.zoom))
		case "0":
			set_zoom(1)
		case "q":
			platform.quit()
		case "k":
			palette.toggle_palette()
		case "l":
			if song, persistent_id, is_song := playback.find_playing_song(); is_song {
				if playback.can_favourite(song) {
					playback.toggle_favourite(song, persistent_id)
				} else {
					kit.show_toast("Favourites need Music.app.")
				}
			}
		}
	}
}
