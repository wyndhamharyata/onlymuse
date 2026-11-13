package lists

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/matching"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

SONG_ROW_POINTS :: 54

SONG_ARTWORK_POINTS :: 40

build_song_list_page :: proc(
	title, description: string,
	songs: []core.Catalog_Song,
	phase: apple.Phase,
	dates: []string = nil,
) {
	page := look.page_scroll("song_list")
	if ui.scope(page) {
		header := ui.box(
			"header",
			{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10},
		)

		if ui.scope(header) {
			heading := ui.box(
				"heading",
				{width = ui.fill(), height = ui.fit_children(), axis = .Y},
			)

			if ui.scope(heading) {
				kit.heading(title)

				count_text := fmt.tprintf("%d songs", len(songs))
				if description != "" {
					count_text = fmt.tprintf("%s · %s", count_text, description)
				}

				kit.text(
					count_text if phase == .Ready else look.to_phase_text(phase),
					kit.with_opacity(kit.colors.base_content, 0.7),
				)
			}

			if phase == .Ready && len(songs) > 0 do build_play_buttons(songs)
		}

		if phase == .Loading do look.build_loading(title)

		if phase == .Ready {
			if len(songs) == 0 do kit.text("Nothing here yet.", kit.with_opacity(kit.colors.base_content, 0.7), is_wrapped = true)
			build_song_rows(songs, dates)
		}
	}
}

build_play_buttons :: proc(songs: []core.Catalog_Song) {
	if kit.button("play", "Play", "play.fill", .Primary).is_activated do playback.play_songs(songs, 0)
	if kit.button("shuffle", "Shuffle", "shuffle").is_activated do playback.shuffle_songs(songs)
}

to_visible_range :: proc(
	offset_points, view_points, step_points: f32,
	count, extra_count: int,
) -> (
	first, last: int,
) {
	first = max(0, int(offset_points / step_points) - extra_count)
	last = min(count - 1, int((offset_points + view_points) / step_points) + extra_count)

	return
}

build_song_rows :: proc(songs: []core.Catalog_Song, dates: []string = nil) {
	style := ui.Style {
		width  = ui.fill(),
		height = ui.fit_children(),
	}

	if first, last, ok := kit.list("rows", len(songs), SONG_ROW_POINTS, style); ok {
		for index in first ..< last {
			song := songs[index]
			is_current := playback.is_current_song(song)
			subtitle := song.album_name if dates != nil else to_song_subtitle(song)
			date := look.to_date_text(dates[index]) if index < len(dates) else ""

			if build_song_row(
				fmt.tprintf("%d %s", index, song.id),
				song,
				subtitle,
				is_current,
				date,
			) {
				playback.play_songs(songs, index)
			}
		}
	}
}

to_song_subtitle :: proc(song: core.Catalog_Song) -> string {
	return(
		fmt.tprintf("%s · %s", song.artist_name, song.album_name) if song.album_name != "" else song.artist_name \
	)
}

build_song_row :: proc(
	id: string,
	song: core.Catalog_Song,
	subtitle: string,
	is_current: bool,
	date := "",
) -> bool {
	tint := kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
	row := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.points(SONG_ROW_POINTS),
			axis = .X,
			align = .Center,
			gap = 11,
			padding = {6, 0, 6, 0},
			corner_radius = 7,
			background = tint if is_current else {},
			hover_background = tint if is_current else kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY),
			press_background = kit.with_opacity(kit.colors.base_content, kit.SELECTED_OPACITY),
			pointer = .Click,
		},
	)

	if ui.scope(row) {
		look.artwork_box(
			apple.to_artwork_url(song.artwork, look.to_artwork_pixels(SONG_ARTWORK_POINTS)),
			SONG_ARTWORK_POINTS,
			5,
			look.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			kit.text(song.name, kit.colors.primary if is_current else kit.colors.base_content)
			kit.text(subtitle, kit.with_opacity(kit.colors.base_content, 0.7), 12)
		}

		if date != "" {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = kit.with_opacity(kit.colors.base_content, 0.5),
					font_size = 12,
				},
				date,
			)
		}

		build_row_heart(song, is_current)
		ui.box(
			"",
			{
				width = ui.points(44),
				height = ui.fit_text(),
				text_align = .End,
				text_color = kit.with_opacity(kit.colors.base_content, 0.5),
				font_size = 12,
			},
			look.to_clock_text(song.duration_seconds),
		)
	}

	return menus.apply_song_row_signal(ui.signal(row), song)
}

build_row_heart :: proc(chosen: core.Catalog_Song, is_current: bool) {
	song, state := matching.watch_match(chosen)

	if state != .Found {
		kit.icon_box(
			YOUTUBE_SYMBOL,
			13,
			look.colors.youtube if state == .Missing else kit.with_opacity(kit.colors.base_content, 0.5),
			{padding = {4, 4, 4, 4}},
		)
	}

	if state == .Checking do return
	if !playback.can_favourite(song) do return

	persistent_id := core.app.now_playing.song.persistent_id if is_current else ""
	is_favourite := playback.is_favourite(song, persistent_id)

	if playback.build_favourite_button("heart", is_favourite) {
		playback.toggle_favourite(song, persistent_id)
	}
}
