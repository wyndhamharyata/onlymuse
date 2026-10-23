package player

import "core:math"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:helper"
import "om:platform"
import "om:ui"

CLOCK_WIDTH_POINTS :: 34

SHUFFLE_RULES_OFFSET_POINTS :: [2]f32{-130, -190}

build_controls :: proc() {
	now_playing := core.app.now_playing
	is_playing := now_playing.playback == .Playing
	has_song := helper.has_song(now_playing)
	controls := ui.box(
		"controls",
		{width = ui.fill(1.25), height = ui.fit_children(), axis = .Y, align = .Center, gap = 6},
	)

	if ui.scope(controls) {
		buttons := ui.box(
			"buttons",
			{
				width = ui.fit_children(),
				height = ui.fit_children(),
				axis = .X,
				align = .Center,
				gap = 16,
			},
		)

		if ui.scope(buttons) {
			shuffle_color := core.app.accent if playback.queue.is_shuffled else kit.colors.faint
			shuffle := kit.icon_box(
				"shuffle",
				"shuffle",
				14,
				shuffle_color,
				{
					padding = {4, 4, 4, 4},
					corner_radius = 6,
					hover_background = kit.colors.hover,
					press_background = kit.colors.selected,
					flags = {.Clickable},
				},
			)

			shuffle_signal := ui.signal(shuffle)
			if shuffle_signal.is_clicked do playback.toggle_shuffle()
			if shuffle_signal.is_right_clicked {
				playback.open_shuffle_rules(shuffle.rect.xy + SHUFFLE_RULES_OFFSET_POINTS)
			}

			resume_seconds :=
				playback.queue.resume_point.position_seconds if playback.is_resume_shown() else helper.read_position_seconds(now_playing)

			if kit.icon_button("previous", "backward.fill", 17, kit.colors.text) {
				playback.skip_to_previous(resume_seconds)
			}

			play := ui.box(
				"play",
				{
					width = ui.points(34),
					height = ui.points(34),
					corner_radius = 17,
					background = kit.colors.text,
					hover_background = kit.colors.white,
					flags = {.Clickable},
				},
			)

			play_symbol := "pause.fill" if is_playing else "play.fill"
			paint := new(kit.Icon_Paint, context.temp_allocator)
			paint^ = {play_symbol, 15, kit.colors.ink}
			play.draw = kit.draw_icon
			play.data = paint

			is_play_clicked := ui.signal(play).is_clicked

			if is_play_clicked && playback.is_resume_shown() {
				playback.resume_last_song()
			} else if is_play_clicked {
				helper.send_play_pause()
			}

			if kit.icon_button("next", "forward.fill", 17, kit.colors.text) {
				playback.skip_to_next()
			}

			repeat_symbol := "repeat.1" if playback.queue.repeat == "one" else "repeat"
			repeat_color := core.app.accent if playback.queue.repeat != "off" else kit.colors.faint

			if kit.icon_button("repeat", repeat_symbol, 14, repeat_color) {
				playback.cycle_repeat()
			}
		}

		build_progress(has_song)
	}
}

build_progress :: proc(has_song: bool) {
	now_playing := core.app.now_playing
	shown, has_shown_song := playback.find_shown_song()
	is_waiting := is_waiting_for_queue_song()
	duration_seconds, position_seconds: f64

	if is_waiting {
		duration_seconds = playback.queue.songs[playback.queue.index].duration_seconds
	} else if has_song {
		duration_seconds = shown.duration_seconds
		position_seconds = helper.read_position_seconds(now_playing)
	} else if has_shown_song {
		duration_seconds = shown.duration_seconds
		position_seconds = playback.queue.resume_point.position_seconds
	}

	ratio := f32(position_seconds / duration_seconds) if duration_seconds > 0 else 0
	progress := ui.box(
		"progress",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 10},
	)

	if ui.scope(progress) {
		clock := ui.box(
			"",
			{
				width = ui.points(CLOCK_WIDTH_POINTS),
				height = ui.fit_text(),
				text_align = .End,
				text_color = kit.colors.faint,
				font_size = 11,
			},
			"",
		)
		shown_ratio, is_set := kit.bar("seek", ratio, ui.fill())
		clock.text = kit.to_clock_text(f64(shown_ratio) * duration_seconds)
		kit.text_box(
			kit.to_clock_text(duration_seconds),
			kit.colors.faint,
			11,
			width = ui.points(CLOCK_WIDTH_POINTS),
		)

		can_seek := is_set && has_song && !is_waiting
		if can_seek do helper.send_seek(f64(shown_ratio) * duration_seconds)
	}

	// Nothing else draws a frame when the clock text changes, so this timer asks for one.
	if now_playing.playback == .Playing && !is_waiting {
		next_second := 1 - (position_seconds - math.floor(position_seconds))
		platform.request_frame_after(next_second + TIMER_SLACK_SECONDS)
	}
}

build_player_end :: proc() {
	end := ui.box(
		"end",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(end) {
		kit.spacer()
		panel_color := core.app.accent if core.app.panel != .None else kit.colors.faint

		if kit.icon_button("panel", "sidebar.right", 16, panel_color) {
			core.set_panel(.None if core.app.panel != .None else core.app.last_panel)
		}

		kit.icon_box("", "speaker.wave.2.fill", 15, kit.colors.dim)

		volume_percent := core.app.now_playing.volume_percent
		shown_ratio, is_set := kit.bar("volume", f32(volume_percent / 100), ui.points(80))

		if is_set {
			percent := int(math.round(shown_ratio * 100))
			helper.send_set_volume(percent)
			core.app.now_playing.volume_percent = f64(percent)
		}
	}
}
