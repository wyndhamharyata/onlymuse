package app

import "core:fmt"
import "core:math"
import "om:helper"
import "om:platform"
import "om:ui"

PLAYER_ARTWORK_POINTS :: 52

build_player_bar :: proc() {
	bar_box := ui.box("player", {
		width        = ui.fill(),
		height       = ui.points(PLAYER_HEIGHT_POINTS),
		axis         = .X,
		align        = .Center,
		gap          = 20,
		padding      = {20, 0, 20, 0},
		background   = colors.player,
	})

	if ui.scope(bar_box) {
		ui.box("", {width = ui.fill(), height = ui.points(1), background = colors.line, position = {0, 0}, flags = {.Floating}})
		build_song_info()
		build_controls()
		build_player_end()
	}
}

build_song_info :: proc() {
	now_playing := app.now_playing
	is_song := now_playing.playback == .Playing || now_playing.playback == .Paused
	info := ui.box("info", {width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12})

	if ui.scope(info) {
		artwork_box(now_playing.song.artwork_path if is_song else "", PLAYER_ARTWORK_POINTS, 6)

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			if is_song {
				song := now_playing.song
				text_box(song.name, colors.text, 13.5, .Semibold)
				text_box(fmt.tprintf("%s · %s", song.artist, song.album), colors.dim, 12.5)
			} else {
				text_box("Not playing", colors.text, 13.5, .Semibold)
				text_box("Music.app is closed" if now_playing.playback == .Closed else "Nothing in Music.app", colors.dim, 12.5)
			}
		}
	}
}

build_controls :: proc() {
	now_playing := app.now_playing
	is_playing := now_playing.playback == .Playing
	is_song := is_playing || now_playing.playback == .Paused
	controls := ui.box("controls", {width = ui.fill(1.25), height = ui.fit_children(), axis = .Y, align = .Center, gap = 6})

	if ui.scope(controls) {
		buttons := ui.box("buttons", {width = ui.fit_children(), height = ui.fit_children(), axis = .X, align = .Center, gap = 16})

		if ui.scope(buttons) {
			icon_button("shuffle", "shuffle", 14, colors.faint, false)
			if icon_button("previous", "backward.fill", 17, colors.text) do helper.send(`{"type":"previous"}`)

			play := ui.box("play", {
				width            = ui.points(34),
				height           = ui.points(34),
				corner_radius    = 17,
				background       = colors.text,
				hover_background = to_color(0xffffffff),
				flags            = {.Clickable},
			})
			paint := new(Icon_Paint, context.temp_allocator)
			paint^ = {"pause.fill" if is_playing else "play.fill", 15, colors.ink}
			play.draw = draw_icon
			play.data = paint
			if ui.signal(play).is_clicked do helper.send(`{"type":"playPause"}`)

			if icon_button("next", "forward.fill", 17, colors.text) do helper.send(`{"type":"next"}`)
			icon_button("repeat", "repeat", 14, colors.faint, false)
		}

		build_progress(is_song)
	}
}

build_progress :: proc(is_song: bool) {
	now_playing := app.now_playing
	duration_seconds := now_playing.song.duration_seconds if is_song else 0
	position_seconds := helper.position_seconds(now_playing) if is_song else 0
	ratio := f32(position_seconds / duration_seconds) if duration_seconds > 0 else 0
	progress := ui.box("progress", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 10})

	if ui.scope(progress) {
		clock := ui.box("", {width = ui.points(34), height = ui.fit_text(), text_align = .End, text_color = colors.faint, font_size = 11}, "")
		shown_ratio, is_set := bar("seek", ratio, ui.fill())
		clock.text = to_clock_text(f64(shown_ratio) * duration_seconds)
		text_box(to_clock_text(duration_seconds), colors.faint, 11, width = ui.points(34))

		if is_set && is_song do helper.send(fmt.tprintf(`{{"type":"seek","positionSeconds":%.3f}}`, f64(shown_ratio) * duration_seconds))
	}

	// The clock turns over on each whole second while a song plays, and nothing else draws between.
	if now_playing.playback == .Playing {
		platform.request_frame_after(1 - (position_seconds - math.floor(position_seconds)) + 0.005)
	}
}

build_player_end :: proc() {
	end := ui.box("end", {width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12})

	if ui.scope(end) {
		spacer()

		if icon_button("lyrics", "quote.bubble", 16, app.accent if app.panel == .Lyrics else colors.faint) do toggle_panel(.Lyrics)
		if icon_button("queue", "list.bullet", 16, app.accent if app.panel == .Up_Next else colors.faint) do toggle_panel(.Up_Next)

		icon_box("", "speaker.wave.2.fill", 15, colors.dim)

		volume_percent := app.now_playing.volume_percent
		shown_ratio, is_set := bar("volume", f32(volume_percent / 100), ui.points(80))

		if is_set {
			percent := int(math.round(shown_ratio * 100))
			helper.send(fmt.tprintf(`{{"type":"setVolume","volumePercent":%d}}`, percent))
			app.now_playing.volume_percent = f64(percent)
		}
	}
}
