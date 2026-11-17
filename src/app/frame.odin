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
	if dev.capture_path != "" do root.style.bg = kit.colors.base_100
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
	playback.end_shuffle_rules()
	kit.toast(look.PLAYER_HEIGHT)
	build_sign_in_card()
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
	playback.apply_rating_results()
	apply_keys()
	apply_player_menu()
}

// The app menu's first item switches between the web player and Music.app, checked while Music.app plays.
@(private = "file")
apply_player_menu :: proc() {
	items := []platform.Menu_Item{{id = "music_app", label = "Play in Music.app", is_checked = core.app.drives_music_app}}
	app.set_menu_items(items)

	if ui.is_menu_picked("music_app") do core.set_player_mode(!core.app.drives_music_app)
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
	apply_playback_keys()
	apply_command_keys()
}

// True when key was pressed this frame with exactly modifiers, and keyboard focus didn't use it.
@(private = "file")
is_shortcut :: proc(key: platform.Key, modifiers: platform.Modifiers) -> bool {
	return ui.is_key_pressed(key) && !ui.is_key_taken(key) && ui.press_modifiers(key) == modifiers
}

@(private = "file")
DIGIT_KEYS := [10]platform.Key{.Digit_0, .Digit_1, .Digit_2, .Digit_3, .Digit_4, .Digit_5, .Digit_6, .Digit_7, .Digit_8, .Digit_9}

@(private = "file")
apply_playback_keys :: proc() {
	if is_shortcut(.Space, {}) do playback.toggle_playback()
	if is_shortcut(.Left, {}) do playback.seek_by_seconds(-playback.SEEK_STEP_SECONDS)
	if is_shortcut(.Right, {}) do playback.seek_by_seconds(playback.SEEK_STEP_SECONDS)
	if is_shortcut(.Left, {.Shift}) do playback.seek_by_seconds(-playback.SEEK_SHIFT_STEP_SECONDS)
	if is_shortcut(.Right, {.Shift}) do playback.seek_by_seconds(playback.SEEK_SHIFT_STEP_SECONDS)

	for key, digit in DIGIT_KEYS {
		if is_shortcut(key, {}) do playback.seek_to_fraction(f64(digit) / 10)
	}
}

@(private = "file")
apply_command_keys :: proc() {
	if is_shortcut(.Left_Bracket, {.Command}) do player.change_lyrics_lead(-1)
	if is_shortcut(.Right_Bracket, {.Command}) do player.change_lyrics_lead(1)
	if is_shortcut(.K, {.Command}) do palette.toggle_palette()
	if is_shortcut(.L, {.Command}) do toggle_playing_favourite()

	// In a text field, the arrows with ⌘ move the caret.
	if kit.has_focused_input() do return

	if is_shortcut(.Left, {.Command}) do playback.skip_to_prev(helper.read_pos_seconds(core.app.now_playing))
	if is_shortcut(.Right, {.Command}) do playback.skip_to_next()
	if is_shortcut(.Up, {.Command}) do playback.change_volume(playback.VOLUME_STEP_PERCENT)
	if is_shortcut(.Down, {.Command}) do playback.change_volume(-playback.VOLUME_STEP_PERCENT)
	if is_shortcut(.Down, {.Command, .Option}) do playback.toggle_mute()
}

@(private = "file")
toggle_playing_favourite :: proc() {
	song, persistent_id, is_song := playback.find_playing_song()
	if !is_song do return

	if !playback.can_favourite(song) {
		kit.show_toast("This song can't be a favourite.", .Warning)
		return
	}

	playback.toggle_favourite(song, persistent_id)
}
