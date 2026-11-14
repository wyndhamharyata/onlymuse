package player

import "core:fmt"
import "core:math"
import "core:time"
import "om:app/core"
import "om:app/look"
import "om:app/playback"
import "om:helper"
import "thor:kit"
import "thor:ui"

CLOCK_WIDTH :: 34

SHUFFLE_RULES_OFFSET :: [2]f32{-130, -190}

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
			shuffle_color := kit.colors.primary if playback.queue.is_shuffled else kit.with_opacity(kit.colors.base_content, 0.5)
			shuffle := kit.button("shuffle", "Shuffle", "shuffle", variant = .Ghost, icon_size = 14, icon_color = shuffle_color, is_label_hidden = true)
			if shuffle.is_activated do playback.toggle_shuffle()
			if shuffle.is_secondary {
				playback.open_shuffle_rules(shuffle.box.rect.xy + SHUFFLE_RULES_OFFSET)
			}

			resume_seconds :=
				playback.queue.resume_point.pos_seconds if playback.is_resume_shown() else helper.read_pos_seconds(now_playing)

			if kit.button("prev", "Previous", "backward.fill", variant = .Ghost, icon_size = 17, is_label_hidden = true).is_activated {
				playback.skip_to_prev(resume_seconds)
			}

			play := ui.box(
				"play",
				{
					width = ui.points(34),
					height = ui.points(34),
					corner_radius = 17,
					bg = kit.colors.base_content,
					hover_bg = {1, 1, 1, 1},
					pointer = .Click,
				},
			)

			play.role, play.label = .Button, "Pause" if is_playing else "Play"
			play_symbol := "pause.fill" if is_playing else "play.fill"
			// The symbol's box fills the circle, so the symbol sits in its middle.
			if ui.scope(play) do kit.icon_box(play_symbol, 15, kit.colors.base_200, {width = ui.fill(), height = ui.fill()})

			is_play_clicked := ui.signal(play).is_activated

			if is_play_clicked && playback.is_resume_shown() {
				playback.resume_last_song()
			} else if is_play_clicked {
				helper.send_play_pause()
			}

			if kit.button("next", "Next", "forward.fill", variant = .Ghost, icon_size = 17, is_label_hidden = true).is_activated {
				playback.skip_to_next()
			}

			repeat_symbol := "repeat.1" if playback.queue.repeat == "one" else "repeat"
			repeat_color :=
				kit.colors.primary if playback.queue.repeat != "off" else kit.with_opacity(kit.colors.base_content, 0.5)

			if kit.button("repeat", "Repeat", repeat_symbol, variant = .Ghost, icon_size = 14, icon_color = repeat_color, is_label_hidden = true).is_activated {
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
	duration_seconds, pos_seconds: f64

	if is_waiting {
		duration_seconds = playback.queue.songs[playback.queue.index].duration_seconds
	} else if has_song {
		duration_seconds = shown.duration_seconds
		pos_seconds      = helper.read_pos_seconds(now_playing)
	} else if has_shown_song {
		duration_seconds = shown.duration_seconds
		pos_seconds      = playback.queue.resume_point.pos_seconds
	}

	ratio := f32(pos_seconds / duration_seconds) if duration_seconds > 0 else 0
	progress := ui.box(
		"progress",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 10},
	)

	if ui.scope(progress) {
		clock := ui.box(
			"",
			{
				width = ui.points(CLOCK_WIDTH),
				height = ui.fit_text(),
				text_align = .End,
				text_color = kit.with_opacity(kit.colors.base_content, 0.5),
				font_size = 11,
			},
			"",
		)
		shown_ratio := ratio
		seek := kit.slider("seek", &shown_ratio, "Position", is_label_hidden = true, is_set_on_release = true, tone = .Base, width = ui.fill())
		clock.text = look.to_clock_text(f64(shown_ratio) * duration_seconds)
		seek.box.value = fmt.tprintf("%s of %s", clock.text, look.to_clock_text(duration_seconds))
		kit.text(
			look.to_clock_text(duration_seconds),
			kit.with_opacity(kit.colors.base_content, 0.5),
			11,
			width = ui.points(CLOCK_WIDTH),
		)

		can_seek := seek.is_changed && has_song && !is_waiting
		if can_seek do helper.send_seek(f64(shown_ratio) * duration_seconds)
	}

	// Nothing else draws a frame when the clock text changes, so this timer asks for one.
	if now_playing.playback == .Playing && !is_waiting {
		next_second := 1 - (pos_seconds - math.floor(pos_seconds))
		ui.request_frame_after(time.Duration((next_second + TIMER_SLACK_SECONDS) * f64(time.Second)))
	}
}

build_player_end :: proc() {
	end := ui.box(
		"end",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(end) {
		ui.box("", {width = ui.fill(), height = ui.points(1)})
		panel_color := kit.colors.primary if core.app.panel != .None else kit.with_opacity(kit.colors.base_content, 0.5)

		if kit.button("panel", "Panel", "sidebar.right", variant = .Ghost, icon_color = panel_color, is_label_hidden = true).is_activated {
			core.set_panel(.None if core.app.panel != .None else core.app.last_panel)
		}

		kit.icon_box("speaker.wave.2.fill", 15, kit.with_opacity(kit.colors.base_content, 0.7))

		shown_ratio := f32(core.app.now_playing.volume_percent / 100)
		volume := kit.slider("volume", &shown_ratio, "Volume", is_label_hidden = true, is_set_on_release = true, tone = .Base, width = ui.points(80))

		if volume.is_changed {
			percent := int(math.round(shown_ratio * 100))
			helper.send_set_volume(percent)
			core.app.now_playing.volume_percent = f64(percent)
		}
	}
}
