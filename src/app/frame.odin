package main

import "core:strings"
import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "om:app/palette"
import "om:app/playback"
import "om:app/player"
import "om:app/youtube_lists"
import "om:app/youtube_pages"
import "om:apple"
import "om:console"
import "om:helper"
import "thor:app"
import "thor:dev"
import "thor:kit"
import "thor:platform"
import "thor:ui"

draw_frame :: proc() -> bool {
	since_last := app.begin_frame()
	core.free_retired_memory()
	playback.free_retired_songs()
	youtube_lists.free_unused_youtube_lists()
	apply_input()
	look.set_accent(since_last, player.find_player_artwork_source())

	root := ui.current_parent()
	root.style.axis = .Y
	if dev.capture_path != "" do root.style.background = kit.colors.base_100
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
	kit.build_toast(look.PLAYER_HEIGHT_POINTS)
	if core.app.is_sign_in_needed do build_sign_in_card()
	dev.build_frame_time(kit.with_opacity(kit.colors.base_content, 0.5))

	is_frame_wanted := app.end_frame()
	save_scroll_at_rest()

	return is_frame_wanted || is_lyrics_moving
}

apply_input :: proc() {
	apply_helper_messages()
	playback.update_queue()
	playback.apply_now_playing_to_play_log()
	menus.apply_write_results()
	apply_keys()
}

save_scroll_at_rest :: proc() {
	is_scroll_at_rest := core.is_scroll_changed && !ui.is_animating()
	if !is_scroll_at_rest do return

	core.is_scroll_changed = false
	core.save_navigation()
}

apply_helper_messages :: proc() {
	for message in helper.take_messages() {
		helper.apply(&core.app.now_playing, message)

		switch message.type {
		case "accent":
			core.app.system_accent = kit.to_color_from_hex(message.color) or_else kit.DEFAULT_PRIMARY
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
		// Once a control has keyboard focus, Tab, the arrows, Return and Space move or use it.
		if !is_key || ui.is_key_taken(key.key) do continue

		if .Command in key.modifiers {
			apply_command_key(key)
		} else {
			apply_playback_key(key)
		}
	}
}

@(private = "file")
apply_playback_key :: proc(key: platform.Key_Press) {
	#partial switch key.key {
	case .Space:
		playback.toggle_playback()
	case .Left, .Right:
		step :=
			playback.SEEK_SHIFT_STEP_SECONDS if .Shift in key.modifiers else playback.SEEK_STEP_SECONDS
		if key.key == .Left do step = -step

		playback.seek_by_seconds(step)
	}

	if len(key.characters) == 1 && key.characters[0] >= '0' && key.characters[0] <= '9' {
		playback.seek_to_fraction(f64(key.characters[0] - '0') / 10)
	}
}

@(private = "file")
apply_command_key :: proc(key: platform.Key_Press) {
	player.apply_lead_key(key)

	if !kit.has_focused_input() {
		#partial switch key.key {
		case .Left:
			playback.skip_to_previous(helper.read_position_seconds(core.app.now_playing))
		case .Right:
			playback.skip_to_next()
		case .Up:
			playback.change_volume(playback.VOLUME_STEP_PERCENT)
		case .Down:
			if .Option in key.modifiers {
				playback.toggle_mute()
			} else {
				playback.change_volume(-playback.VOLUME_STEP_PERCENT)
			}
		}
	}

	switch key.characters {
	case "k":
		palette.toggle_palette()
	case "l":
		if song, persistent_id, is_song := playback.find_playing_song(); is_song {
			if playback.can_favourite(song) {
				playback.toggle_favourite(song, persistent_id)
			} else {
				kit.show_toast("Favourites need Music.app.", .Warning)
			}
		}
	}
}
