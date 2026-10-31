package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:apple"
import "om:font"
import "om:helper"
import "om:ui"
import "om:youtube"

PLAYER_ARTWORK_POINTS :: 52

SONG_NAME_FONT_SIZE :: 13.5

SONG_NAME_WEIGHT :: font.Weight.Semibold

BADGE_FONT_SIZE :: 9.5

BADGE_WEIGHT :: font.Weight.Bold

BADGE_PADDING_POINTS :: 4

TITLE_GAP_POINTS :: 7

HEART_BUTTON_POINTS :: 22

build_player_bar :: proc() {
	bar_box := ui.box(
		"player",
		{
			width = ui.fill(),
			height = ui.points(kit.PLAYER_HEIGHT_POINTS),
			axis = .X,
			align = .Center,
			gap = 16,
			padding = {16, 0, 16, 0},
			background = kit.colors.player,
		},
	)

	if ui.scope(bar_box) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.points(1),
				background = kit.colors.line,
				position = {0, 0},
				flags = {.Floating},
			},
		)

		build_song_info()
		build_controls()
		build_player_end()
	}
}

@(private)
is_waiting_for_queue_song :: proc() -> bool {
	return playback.queue.is_adding || playback.is_starting_youtube_song()
}

find_player_artwork_source :: proc() -> string {
	if is_waiting_for_queue_song() {
		return apple.to_artwork_url(
			playback.queue.songs[playback.queue.index].artwork,
			kit.to_artwork_pixels(PLAYER_ARTWORK_POINTS),
		)
	}

	song, is_song := playback.find_shown_song()
	queue_song, is_queue_song := playback.find_queue_song(song.persistent_id)

	if is_queue_song && queue_song.artwork.url != "" {
		return apple.to_artwork_url(
			queue_song.artwork,
			kit.to_artwork_pixels(PLAYER_ARTWORK_POINTS),
		)
	}

	return song.artwork_path if is_song else ""
}

build_song_info :: proc() {
	now_playing := core.app.now_playing
	song, is_song := playback.find_shown_song()
	queue_song, is_queue_song := playback.find_queue_song(song.persistent_id)
	is_waiting := is_waiting_for_queue_song()
	waiting_song := playback.queue.songs[playback.queue.index] if is_waiting else {}
	info := ui.box(
		"info",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(info) {
		artwork_source := find_player_artwork_source()
		placeholder := kit.to_placeholder({}, song.album_name)

		if is_waiting {
			placeholder = kit.to_placeholder(waiting_song.artwork, waiting_song.album_name)
		} else if !is_song {
			placeholder = {
				top    = kit.colors.card,
				bottom = kit.colors.card,
			}
		} else if is_queue_song {
			placeholder = kit.to_placeholder(queue_song.artwork, queue_song.album_name)
		}

		// odinfmt cannot read `{.Clickable} if ...` inside another literal, so a local holds it.
		cover_flags: ui.Flags = {.Clickable} if is_song else {}
		cover := ui.box(
			"cover",
			{width = ui.fit_children(), height = ui.fit_children(), flags = cover_flags},
		)
		if ui.signal(cover).is_clicked do core.navigate({kind = .Now_Playing})

		if ui.scope(cover) {
			kit.artwork_box(artwork_source, PLAYER_ARTWORK_POINTS, 6, placeholder)
			ui.box(
				"",
				{
					width = ui.points(PLAYER_ARTWORK_POINTS),
					height = ui.points(PLAYER_ARTWORK_POINTS),
					corner_radius = 6,
					background = {1, 1, 1, 0.12 * cover.hot_fraction},
					position = {0, 0},
					flags = {.Floating},
				},
			)
		}

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			if is_waiting {
				waiting_text := "Loading…"
				if playback.queue.is_adding {
					waiting_text = "Adding to library…"
				} else if youtube.is_song_id(waiting_song.id) {
					waiting_text = "Loading from YouTube…"
				}

				kit.text_box(
					waiting_song.name,
					kit.colors.text,
					SONG_NAME_FONT_SIZE,
					SONG_NAME_WEIGHT,
				)
				kit.text_box(waiting_text, kit.colors.dim, kit.SMALL_TEXT_POINTS)
			} else if is_song {
				build_song_title(song, queue_song, is_queue_song)
				build_song_subtitle(song)
			} else {
				kit.text_box(
					"Nothing is playing.",
					kit.colors.text,
					SONG_NAME_FONT_SIZE,
					SONG_NAME_WEIGHT,
				)

				if core.app.drives_music_app {
					closed_text :=
						"Music.app is not open." if now_playing.playback == .Closed else "Music.app has no song."
					kit.text_box(closed_text, kit.colors.dim, kit.SMALL_TEXT_POINTS)
				}
			}
		}
	}
}

@(private = "file")
build_song_title :: proc(song: helper.Song, queue_song: core.Catalog_Song, is_queue_song: bool) {
	title := ui.box(
		"title",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .X,
			align = .Center,
			gap = TITLE_GAP_POINTS,
		},
	)

	if ui.scope(title) {
		is_from_youtube := is_queue_song && youtube.is_song_id(queue_song.id)
		badge := ""

		if is_from_youtube {
			badge = "YOUTUBE"
		} else if is_queue_song && queue_song.is_lossless && core.app.drives_music_app {
			badge = "LOSSLESS"
		}

		badge_color := kit.colors.youtube if is_from_youtube else kit.colors.dim
		badge_border_color := kit.colors.youtube if is_from_youtube else kit.colors.faint
		name_width := ui.Size{.Fill, 1}

		if row_width := title.rect.z - title.rect.x; row_width > 0 {
			after_width: f32 = HEART_BUTTON_POINTS + TITLE_GAP_POINTS

			if badge != "" {
				badge_width :=
					kit.measure_text(badge, BADGE_FONT_SIZE, BADGE_WEIGHT) +
					2 * BADGE_PADDING_POINTS
				after_width += badge_width + TITLE_GAP_POINTS
			}

			// At exactly its text width, a name such as "If" truncates to nothing.
			name_text_width :=
				kit.measure_text(song.name, SONG_NAME_FONT_SIZE, SONG_NAME_WEIGHT) + 1
			name_width = ui.points(min(name_text_width, row_width - after_width))
		}

		kit.scrolling_text(
			"name",
			song.name,
			kit.colors.text,
			SONG_NAME_FONT_SIZE,
			SONG_NAME_WEIGHT,
			width = name_width,
		)

		if badge != "" {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					padding = {BADGE_PADDING_POINTS, 0, BADGE_PADDING_POINTS, 0},
					corner_radius = 4,
					border_width = 1,
					border_color = badge_border_color,
					text_color = badge_color,
					font_size = BADGE_FONT_SIZE,
					font_weight = BADGE_WEIGHT,
				},
				badge,
			)
		}

		playing, persistent_id, _ := playback.find_playing_song()
		if !playback.is_web_played(persistent_id) do playback.watch_song_info(persistent_id)

		if playback.can_favourite(playing) &&
		   playback.build_favourite_button(
			   "favourite",
			   playback.is_favourite(playing, persistent_id),
		   ) {
			playback.toggle_favourite(playing, persistent_id)
		}
	}
}

@(private = "file")
build_song_subtitle :: proc(song: helper.Song) {
	now_playing := core.app.now_playing
	// Music.app says Playing during a load. A stall before the start shows the load.
	is_loading :=
		now_playing.playback == .Playing && !now_playing.has_started && now_playing.stall_count > 0
	subtitle_text :=
		fmt.tprintf("%s · %s", song.artist_name, song.album_name) if song.album_name != "" else song.artist_name
	if is_loading do subtitle_text = "Loading in Music.app…"
	subtitle := kit.scrolling_text(
		"subtitle",
		subtitle_text,
		kit.colors.dim,
		kit.SMALL_TEXT_POINTS,
		is_clickable = true,
	)

	if ui.signal(subtitle).is_clicked {
		core.navigate({kind = .Artist, title = fmt.aprint(song.artist_name)})
	}
}
