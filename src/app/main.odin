package main

import "base:runtime"
import "core:os"
import "om:app/core"
import "om:app/look"
import "om:app/matching"
import "om:app/menus"
import "om:app/palette"
import "om:app/playback"
import "om:app/player"
import "om:apple"
import "om:helper"
import "om:macos"
import "om:store"
import "om:youtube"
import "thor:app"
import "thor:dev"
import "thor:kit"
import "thor:platform"
import "thor:ui"

// A long page needs more than the 256 KB that build.sh gives a thread.
MAIN_TEMP_BYTES :: 4 * 1024 * 1024

DEFAULT_WINDOW_SIZE_POINTS :: [2]f32{1200, 800}

main :: proc() {
	runtime.default_temp_allocator_init(
		&runtime.global_default_temp_allocator_data,
		MAIN_TEMP_BYTES,
		context.allocator,
	)

	dev.start()
	start_app_state()
	start_parts()

	helper.start(dev.is_background)
	core.start_player_mode()
	start_covers()
	open_main_window()

	platform.run()
}

start_app_state :: proc() {
	// onlymuse stays dark, and its accent follows the playing song's cover.
	kit.appearance = .Dark
	kit.dark_colors.base_100 = kit.to_color(look.WINDOW_COLOR)
	kit.dark_colors.primary = kit.DEFAULT_PRIMARY
	core.app.system_accent = kit.DEFAULT_PRIMARY
	core.app.panel = .Lyrics
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

open_main_window :: proc() {
	app.open_main_window(
		{
			title = "onlymuse",
			size = DEFAULT_WINDOW_SIZE_POINTS,
			min_size = {look.MIN_WINDOW_WIDTH_POINTS, look.MIN_WINDOW_HEIGHT_POINTS},
			is_blurred = true,
		},
		draw_frame,
		fetch_cover,
		to_cover_family,
	)
	macos.start(app.native_window, dev.is_background && !dev.is_bench)
	macos.install_player_menu({
		is_driving = proc() -> bool {return core.app.drives_music_app},
		toggle = proc() {core.set_player_mode(!core.app.drives_music_app)},
	})
}

SIGN_IN_CARD_WIDTH_POINTS :: 380

SIGN_IN_CARD_HALF_HEIGHT_POINTS :: 110

build_sign_in_card :: proc() {
	window_size := ui.window_size()
	cover := ui.box(
		"sign_in_cover",
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
				background = kit.colors.base_300,
				border_width = 1,
				border_color = kit.to_faded(kit.colors.base_content, kit.LINE_OPACITY),
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
					text_color = kit.colors.base_content,
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
					text_color = kit.to_faded(kit.colors.base_content, 0.7),
					flags = {.Wrap_Text},
				},
				"onlymuse reads Apple Music with the sign-in of music.apple.com. Apple's own sign-in page opens in a window of its own.",
			)

			label := "Open the sign-in window again" if core.app.is_sign_in_open else "Sign In"

			if kit.button("sign_in", label, "person.crop.circle", .Primary).is_activated {
				core.app.is_sign_in_open = true
				helper.send_sign_in()
			}
		}
	}
}
