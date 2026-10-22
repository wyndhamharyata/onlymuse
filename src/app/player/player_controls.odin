package player

import "core:fmt"
import "core:math"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:helper"
import "om:platform"
import "om:ui"

build_controls :: proc() {
	now_playing := core.app.now_playing
	is_playing := now_playing.playback == .Playing
	is_song := is_playing || now_playing.playback == .Paused
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
			// A right-click opens the shuffle's rules.
			shuffle := kit.icon_box(
				"shuffle",
				"shuffle",
				14,
				core.app.accent if playback.queue.is_shuffled else kit.colors.faint,
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
				playback.open_shuffle_rules({shuffle.rect.x - 130, shuffle.rect.y - 190})
			}

			resume_seconds :=
				playback.queue.resume_point.position_seconds if playback.is_resume_shown() else helper.to_position_seconds(now_playing)

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
					hover_background = kit.to_color(0xffffffff),
					flags = {.Clickable},
				},
			)

			paint := new(kit.Icon_Paint, context.temp_allocator)
			paint^ = {"pause.fill" if is_playing else "play.fill", 15, kit.colors.ink}
			play.draw = kit.draw_icon
			play.data = paint

			is_play_clicked := ui.signal(play).is_clicked

			if is_play_clicked && playback.is_resume_shown() {
				playback.resume_last_song()
			} else if is_play_clicked {
				helper.send(`{"type":"playPause"}`)
			}

			if kit.icon_button("next", "forward.fill", 17, kit.colors.text) {
				playback.skip_to_next()
			}

			repeat_symbol := "repeat.1" if playback.queue.repeat == "one" else "repeat"

			if kit.icon_button(
				"repeat",
				repeat_symbol,
				14,
				core.app.accent if playback.queue.repeat != "off" else kit.colors.faint,
			) {
				playback.cycle_repeat()
			}
		}

		build_progress(is_song)
	}
}

build_progress :: proc(is_playing_song: bool) {
	now_playing := core.app.now_playing
	shown, is_song := playback.find_shown_song()
	// While a song is on its way into the library or the YouTube page loads it, the bar shows its start and its own length. The clock stays still.
	is_waiting := playback.queue.is_adding || playback.is_starting_youtube_song()
	duration_seconds :=
		playback.queue.songs[playback.queue.index].duration_seconds if is_waiting else shown.duration_seconds if is_song else 0
	position_seconds :=
		0 if is_waiting else helper.to_position_seconds(now_playing) if is_playing_song else playback.queue.resume_point.position_seconds if is_song else 0
	ratio := f32(position_seconds / duration_seconds) if duration_seconds > 0 else 0
	progress := ui.box(
		"progress",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 10},
	)

	if ui.scope(progress) {
		clock := ui.box(
			"",
			{
				width = ui.points(34),
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
			width = ui.points(34),
		)

		if is_set && is_playing_song && !is_waiting {
			helper.send(
				fmt.tprintf(
					`{{"type":"seek","positionSeconds":%.3f}}`,
					f64(shown_ratio) * duration_seconds,
				),
			)
		}
	}

	// The clock turns over on each whole second while a song plays. Nothing else draws between those seconds.
	if now_playing.playback == .Playing && !is_waiting {
		platform.request_frame_after(1 - (position_seconds - math.floor(position_seconds)) + 0.005)
	}
}

build_player_end :: proc() {
	end := ui.box(
		"end",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(end) {
		kit.spacer()

		if kit.icon_button(
			"panel",
			"sidebar.right",
			16,
			core.app.accent if core.app.panel != .None else kit.colors.faint,
		) {
			core.toggle_side_panel()
		}

		kit.icon_box("", "speaker.wave.2.fill", 15, kit.colors.dim)

		volume_percent := core.app.now_playing.volume_percent
		shown_ratio, is_set := kit.bar("volume", f32(volume_percent / 100), ui.points(80))

		if is_set {
			percent := int(math.round(shown_ratio * 100))
			helper.send(fmt.tprintf(`{{"type":"setVolume","volumePercent":%d}}`, percent))
			core.app.now_playing.volume_percent = f64(percent)
		}
	}
}
