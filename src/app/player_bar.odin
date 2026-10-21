package app

import "core:fmt"
import "core:math"
import "om:helper"
import "om:apple"
import "om:platform"
import "om:ui"
import "om:youtube"

PLAYER_ARTWORK_POINTS :: 52

build_player_bar :: proc() {
	bar_box := ui.box("player", {
		width        = ui.fill(),
		height       = ui.points(PLAYER_HEIGHT_POINTS),
		axis         = .X,
		align        = .Center,
		gap          = 16,
		padding      = {16, 0, 16, 0},
		background   = colors.player,
	})

	if ui.scope(bar_box) {
		ui.box("", {width = ui.fill(), height = ui.points(1), background = colors.line, position = {0, 0}, flags = {.Floating}})
		build_song_info()
		build_controls()
		build_player_end()
	}
}

// With Music.app stopped or closed, the player shows the last song, paused where it was.
find_shown_song :: proc() -> (helper.Song, bool) {
	now_playing := app.now_playing
	if now_playing.playback == .Playing || now_playing.playback == .Paused do return now_playing.song, true

	resume := queue.resume_point

	return resume.song, resume.song.persistent_id != ""
}

@(private = "file")
is_resume_shown :: proc() -> bool {
	now_playing := app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	return !has_song && queue.resume_point.song.persistent_id != ""
}

// The cover the player bar shows: Music.app's, or Apple's for a song of the queue.
find_player_artwork_source :: proc() -> string {
	if queue.is_adding || is_starting_youtube_song() do return apple.to_artwork_url(queue.songs[queue.index].artwork, to_artwork_pixels(PLAYER_ARTWORK_POINTS))

	song, is_song := find_shown_song()
	queue_song, is_queue_song := find_queue_song(song.persistent_id)
	if is_queue_song && queue_song.artwork.url != "" do return apple.to_artwork_url(queue_song.artwork, to_artwork_pixels(PLAYER_ARTWORK_POINTS))

	return song.artwork_path if is_song else ""
}

build_song_info :: proc() {
	now_playing := app.now_playing
	song, is_song := find_shown_song()
	queue_song, is_queue_song := find_queue_song(song.persistent_id)
	// A song being added to the library, or loaded by the YouTube page, shows before Music.app or the page has it.
	is_waiting := queue.is_adding || is_starting_youtube_song()
	adding_song := queue.songs[queue.index] if is_waiting else {}
	info := ui.box("info", {width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12})

	if ui.scope(info) {
		artwork_source := find_player_artwork_source()
		placeholder := to_placeholder({}, song.album if is_song else "")
		if is_queue_song do placeholder = to_placeholder(queue_song.artwork, queue_song.album_name)
		if is_waiting do placeholder = to_placeholder(adding_song.artwork, adding_song.album_name)
		if !is_song && !is_waiting do placeholder = {top = colors.card, bottom = colors.card}
		// The cover opens the Now Playing page.
		cover := ui.box("cover", {width = ui.fit_children(), height = ui.fit_children(), flags = {.Clickable} if is_song else {}})
		if ui.signal(cover).is_clicked do navigate({kind = .Now_Playing})

		if ui.scope(cover) {
			artwork_box(artwork_source, PLAYER_ARTWORK_POINTS, 6, placeholder)
			ui.box("", {width = ui.points(PLAYER_ARTWORK_POINTS), height = ui.points(PLAYER_ARTWORK_POINTS), corner_radius = 6, background = {1, 1, 1, 0.12 * cover.hot_t}, position = {0, 0}, flags = {.Floating}})
		}

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			if is_waiting {
				text_box(adding_song.name, colors.text, 13.5, .Semibold)
				text_box("Adding to library…" if queue.is_adding else "Loading from YouTube…", colors.dim, 12.5)
			} else if is_song {
				title := ui.box("title", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 7})

				if ui.scope(title) {
					// A song from YouTube says so in place of LOSSLESS.
					is_from_youtube := is_queue_song && youtube.is_song_id(queue_song.id)
					badge := "YOUTUBE" if is_from_youtube else "LOSSLESS" if is_queue_song && queue_song.is_lossless else ""
					badge_color := colors.youtube if is_from_youtube else colors.dim
					name_width := ui.Size{.Fill, 1}

					// Last frame's width of the row, less the badge and the heart, caps the name.
					if row_width := title.rect.z - title.rect.x; row_width > 0 {
						after_width: f32 = 22 + 7
						if badge != "" do after_width += measure_text(badge, 9.5, .Bold) + 8 + 7
						// A point more than the text, as a box exactly as wide cuts a short name such as "If" to nothing.
						name_width = ui.points(min(measure_text(song.name, 13.5, .Semibold) + 1, row_width - after_width))
					}

					scrolling_text("name", song.name, colors.text, 13.5, .Semibold, width = name_width)
					if badge != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), padding = {4, 0, 4, 0}, corner_radius = 4, border_width = 1, border_color = badge_color if is_from_youtube else colors.faint, text_color = badge_color, font_size = 9.5, font_weight = .Bold}, badge)

					// Music.app knows nothing of a song the YouTube page plays.
					playing, persistent_id, _ := find_playing_song()
					if !is_from_youtube do find_track_info(persistent_id)
					if favourite_button("favourite", is_favourite(playing, persistent_id), 13) do toggle_favourite(playing, persistent_id)
				}

				// Go to Artist always opens the Apple Music artist, never the library one.
				// Music.app says it plays while it still loads a song. A position that has not moved by the first check says so.
				is_loading := now_playing.playback == .Playing && !now_playing.has_started && now_playing.stall_count > 0
				subtitle_text := "Loading in Music.app…" if is_loading else fmt.tprintf("%s · %s", song.artist, song.album)
				subtitle := scrolling_text("subtitle", subtitle_text, colors.dim, 12.5, is_clickable = true)
				if ui.signal(subtitle).is_clicked do navigate({kind = .Artist, title = fmt.aprint(song.artist)})
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
			// A right-click opens the shuffle's rules.
			shuffle := icon_box("shuffle", "shuffle", 14, app.accent if queue.is_shuffled else colors.faint, {padding = {4, 4, 4, 4}, corner_radius = 6, hover_background = colors.hover, press_background = colors.selected, flags = {.Clickable}})
			shuffle_signal := ui.signal(shuffle)
			if shuffle_signal.is_clicked do toggle_shuffle()
			if shuffle_signal.is_right_clicked do open_shuffle_rules({shuffle.rect.x - 130, shuffle.rect.y - 190})

			resume_seconds := queue.resume_point.position_seconds if is_resume_shown() else helper.position_seconds(now_playing)
			if icon_button("previous", "backward.fill", 17, colors.text) do skip_to_previous(resume_seconds)

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
			if ui.signal(play).is_clicked {
				if is_resume_shown() {
					resume_last_song()
				} else {
					helper.send(`{"type":"playPause"}`)
				}
			}

			if icon_button("next", "forward.fill", 17, colors.text) do skip_to_next()

			repeat_symbol := "repeat.1" if queue.repeat == "one" else "repeat"
			if icon_button("repeat", repeat_symbol, 14, app.accent if queue.repeat != "off" else colors.faint) do cycle_repeat()
		}

		build_progress(is_song)
	}
}

build_progress :: proc(is_playing_song: bool) {
	now_playing := app.now_playing
	shown, is_song := find_shown_song()
	duration_seconds := shown.duration_seconds if is_song else 0
	position_seconds := helper.position_seconds(now_playing) if is_playing_song else queue.resume_point.position_seconds if is_song else 0
	ratio := f32(position_seconds / duration_seconds) if duration_seconds > 0 else 0
	progress := ui.box("progress", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 10})

	if ui.scope(progress) {
		clock := ui.box("", {width = ui.points(34), height = ui.fit_text(), text_align = .End, text_color = colors.faint, font_size = 11}, "")
		shown_ratio, is_set := bar("seek", ratio, ui.fill())
		clock.text = to_clock_text(f64(shown_ratio) * duration_seconds)
		text_box(to_clock_text(duration_seconds), colors.faint, 11, width = ui.points(34))

		if is_set && is_playing_song do helper.send(fmt.tprintf(`{{"type":"seek","positionSeconds":%.3f}}`, f64(shown_ratio) * duration_seconds))
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

		if icon_button("panel", "sidebar.right", 16, app.accent if app.panel != .None else colors.faint) do toggle_side_panel()

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
