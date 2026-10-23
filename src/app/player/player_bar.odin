// The player bar, the side panel with Up Next and the lyrics, and the Now Playing page.
package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:apple"
import "om:ui"
import "om:youtube"

PLAYER_ARTWORK_POINTS :: 52

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

// Finds the cover the player bar shows. It is Music.app's, or Apple's for a song of the queue.
find_player_artwork_source :: proc() -> string {
	if playback.queue.is_adding || playback.is_starting_youtube_song() {
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

// The left end of the player bar, with the cover, the song, its badge and the heart.
build_song_info :: proc() {
	now_playing := core.app.now_playing
	song, is_song := playback.find_shown_song()
	queue_song, is_queue_song := playback.find_queue_song(song.persistent_id)
	// The queue song shows while it goes into the library or while the YouTube page loads it.
	is_waiting := playback.queue.is_adding || playback.is_starting_youtube_song()
	adding_song := playback.queue.songs[playback.queue.index] if is_waiting else {}
	info := ui.box(
		"info",
		{width = ui.fill(1), height = ui.fit_children(), axis = .X, align = .Center, gap = 12},
	)

	if ui.scope(info) {
		artwork_source := find_player_artwork_source()
		placeholder := kit.to_placeholder({}, song.album if is_song else "")

		if is_queue_song {
			placeholder = kit.to_placeholder(queue_song.artwork, queue_song.album_name)
		}

		if is_waiting {
			placeholder = kit.to_placeholder(adding_song.artwork, adding_song.album_name)
		}

		if !is_song && !is_waiting {
			placeholder = {
				top    = kit.colors.card,
				bottom = kit.colors.card,
			}
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
				kit.text_box(adding_song.name, kit.colors.text, 13.5, .Semibold)
				kit.text_box(
					"Adding to library…" if playback.queue.is_adding else "Loading from YouTube…",
					kit.colors.dim,
					12.5,
				)
			} else if is_song {
				title := ui.box(
					"title",
					{
						width = ui.fill(),
						height = ui.fit_children(),
						axis = .X,
						align = .Center,
						gap = 7,
					},
				)

				if ui.scope(title) {
					// A song from YouTube says so in place of LOSSLESS.
					is_from_youtube := is_queue_song && youtube.is_song_id(queue_song.id)
					badge :=
						"YOUTUBE" if is_from_youtube else "LOSSLESS" if is_queue_song && queue_song.is_lossless else ""
					badge_color := kit.colors.youtube if is_from_youtube else kit.colors.dim
					name_width := ui.Size{.Fill, 1}

					// Last frame's width of the row, less the badge and the heart, caps the name.
					if row_width := title.rect.z - title.rect.x; row_width > 0 {
						after_width: f32 = 22 + 7
						if badge != "" do after_width += kit.measure_text(badge, 9.5, .Bold) + 8 + 7

						// At exactly its text width, a name such as "If" truncates to nothing.
						name_width = ui.points(
							min(
								kit.measure_text(song.name, 13.5, .Semibold) + 1,
								row_width - after_width,
							),
						)
					}

					kit.scrolling_text(
						"name",
						song.name,
						kit.colors.text,
						13.5,
						.Semibold,
						width = name_width,
					)

					if badge != "" {
						ui.box(
							"",
							{
								width = ui.fit_text(),
								height = ui.fit_text(),
								padding = {4, 0, 4, 0},
								corner_radius = 4,
								border_width = 1,
								border_color = badge_color if is_from_youtube else kit.colors.faint,
								text_color = badge_color,
								font_size = 9.5,
								font_weight = .Bold,
							},
							badge,
						)
					}

					// Music.app knows nothing of a song the YouTube page plays.
					playing, persistent_id, _ := playback.find_playing_song()
					if !is_from_youtube do playback.watch_song_info(persistent_id)

					if playback.favourite_button(
						"favourite",
						playback.is_favourite(playing, persistent_id),
						13,
					) {
						playback.toggle_favourite(playing, persistent_id)
					}
				}

				// Music.app says Playing during a load. A stall before the start shows the load.
				is_loading :=
					now_playing.playback == .Playing &&
					!now_playing.has_started &&
					now_playing.stall_count > 0
				// A video on YouTube has no album.
				subtitle_text :=
					fmt.tprintf("%s · %s", song.artist, song.album) if song.album != "" else song.artist
				if is_loading do subtitle_text = "Loading in Music.app…"
				subtitle := kit.scrolling_text(
					"subtitle",
					subtitle_text,
					kit.colors.dim,
					12.5,
					is_clickable = true,
				)

				// The artist page finds the Apple Music artist by this name, never the library one.
				if ui.signal(subtitle).is_clicked {
					core.navigate({kind = .Artist, title = fmt.aprint(song.artist)})
				}
			} else {
				kit.text_box("Not playing", kit.colors.text, 13.5, .Semibold)
				kit.text_box(
					"Music.app is closed" if now_playing.playback == .Closed else "Nothing in Music.app",
					kit.colors.dim,
					12.5,
				)
			}
		}
	}
}
