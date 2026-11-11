package player

import "core:math"
import "om:app/core"
import "om:app/look"
import "om:app/playback"
import "om:helper"
import "thor:kit"
import "thor:ui"

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
			shuffle_color := kit.colors.primary if playback.queue.is_shuffled else kit.to_faded(kit.colors.base_content, 0.5)
			shuffle := kit.button("shuffle", icon = "shuffle", icon_size = 14, icon_color = shuffle_color)
			if shuffle.is_activated do playback.toggle_shuffle()
			if shuffle.is_secondary {
				playback.open_shuffle_rules(shuffle.box.rect.xy + SHUFFLE_RULES_OFFSET_POINTS)
			}

			resume_seconds :=
				playback.queue.resume_point.position_seconds if playback.is_resume_shown() else helper.read_position_seconds(now_playing)

			if kit.button("previous", icon = "backward.fill", icon_size = 17).is_activated {
				playback.skip_to_previous(resume_seconds)
			}

			play := ui.box(
				"play",
				{
					width = ui.points(34),
					height = ui.points(34),
					corner_radius = 17,
					align = .Center,
					justify = .Center,
					background = kit.colors.base_content,
					hover_background = {1, 1, 1, 1},
					flags = {.Clickable},
				},
			)

			play_symbol := "pause.fill" if is_playing else "play.fill"
			if ui.scope(play) do kit.icon_box(play_symbol, 15, kit.colors.base_200)

			is_play_clicked := ui.signal(play).is_activated

			if is_play_clicked && playback.is_resume_shown() {
				playback.resume_last_song()
			} else if is_play_clicked {
				helper.send_play_pause()
			}

			if kit.button("next", icon = "forward.fill", icon_size = 17).is_activated {
				playback.skip_to_next()
			}

			repeat_symbol := "repeat.1" if playback.queue.repeat == "one" else "repeat"
			repeat_color :=
				kit.colors.primary if playback.queue.repeat != "off" else kit.to_faded(kit.colors.base_content, 0.5)

			if kit.button("repeat", icon = repeat_symbol, icon_size = 14, icon_color = repeat_color).is_activated {
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
				text_color = kit.to_faded(kit.colors.base_content, 0.5),
				font_size = 11,
			},
			"",
		)
		shown_ratio := ratio
		seek := kit.slider("seek", &shown_ratio, is_set_on_release = true, tone = .Base, width = ui.fill())
		clock.text = look.to_clock_text(f64(shown_ratio) * duration_seconds)
		kit.text(
			look.to_clock_text(duration_seconds),
			kit.to_faded(kit.colors.base_content, 0.5),
			11,
			width = ui.points(CLOCK_WIDTH_POINTS),
		)

		can_seek := seek.is_changed && has_song && !is_waiting
		if can_seek do helper.send_seek(f64(shown_ratio) * duration_seconds)
	}

	// Nothing else draws a frame when the clock text changes, so this timer asks for one.
	if now_playing.playback == .Playing && !is_waiting {
		next_second := 1 - (position_seconds - math.floor(position_seconds))
		ui.request_frame_after(next_second + TIMER_SLACK_SECONDS)
	}
}

build_player_end :: proc() {
	end := ui.box(
		"end",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(end) {
		ui.box("", {width = ui.fill(), height = ui.points(1)})
		panel_color := kit.colors.primary if core.app.panel != .None else kit.to_faded(kit.colors.base_content, 0.5)

		if kit.button("panel", icon = "sidebar.right", icon_size = 16, icon_color = panel_color).is_activated {
			core.set_panel(.None if core.app.panel != .None else core.app.last_panel)
		}

		kit.icon_box("speaker.wave.2.fill", 15, kit.to_faded(kit.colors.base_content, 0.7))

		shown_ratio := f32(core.app.now_playing.volume_percent / 100)
		volume := kit.slider("volume", &shown_ratio, is_set_on_release = true, tone = .Base, width = ui.points(80))

		if volume.is_changed {
			percent := int(math.round(shown_ratio * 100))
			helper.send_set_volume(percent)
			core.app.now_playing.volume_percent = f64(percent)
		}
	}
}
