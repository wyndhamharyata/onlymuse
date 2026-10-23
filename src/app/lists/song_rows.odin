package lists

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "om:ui"

SONG_ROW_POINTS :: 54

SONG_ARTWORK_POINTS :: 40

EXTRA_ROW_COUNT :: 2

build_song_list_page :: proc(
	title, description: string,
	songs: []core.Catalog_Song,
	phase: apple.Phase,
	dates: []string = nil,
) {
	page := kit.page_scroll("song list")
	kit.run_bench_scroll(page)

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
				kit.page_heading(title)

				count_text := fmt.tprintf("%d songs", len(songs))
				if description != "" {
					count_text = fmt.tprintf("%s · %s", count_text, description)
				}

				kit.text_box(
					count_text if phase == .Ready else kit.to_phase_text(phase),
					kit.colors.dim,
				)
			}

			if phase == .Ready && len(songs) > 0 do build_play_buttons(songs)
		}

		if phase == .Loading do kit.build_loading(title)

		if phase == .Ready {
			if len(songs) == 0 do kit.note("Nothing here yet.")
			build_song_rows(page, songs, dates)
		}
	}
}

build_play_buttons :: proc(songs: []core.Catalog_Song) {
	if kit.action_button("Play", "play.fill", true) do playback.play_songs(songs, 0)
	if kit.action_button("Shuffle", "shuffle", false) do playback.shuffle_songs(songs)
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

build_song_rows :: proc(page: ^ui.Box, songs: []core.Catalog_Song, dates: []string = nil) {
	rows := ui.box("rows", {width = ui.fill(), height = ui.fit_children(), axis = .Y})
	top := core.to_offset_in_page(page, rows)
	first, last := to_visible_range(
		page.scroll - top,
		page.size.y,
		SONG_ROW_POINTS,
		len(songs),
		EXTRA_ROW_COUNT,
	)

	if ui.scope(rows) {
		if first > 0 {
			ui.box("", {width = ui.fill(), height = ui.points(f32(first) * SONG_ROW_POINTS)})
		}

		for index in first ..= last {
			song := songs[index]
			is_current := playback.is_current_song(song)
			subtitle := song.album_name if dates != nil else to_song_subtitle(song)
			date := kit.to_date_text(dates[index]) if index < len(dates) else ""

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

		if last < len(songs) - 1 {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.points(f32(len(songs) - 1 - last) * SONG_ROW_POINTS),
				},
			)
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
	tint := kit.to_accent_tint(core.app.accent)
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
			hover_background = tint if is_current else kit.colors.hover,
			press_background = kit.colors.selected,
			flags = {.Clickable},
		},
	)

	if ui.scope(row) {
		kit.artwork_box(
			apple.to_artwork_url(song.artwork, kit.to_artwork_pixels(SONG_ARTWORK_POINTS)),
			SONG_ARTWORK_POINTS,
			5,
			kit.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			kit.text_box(song.name, core.app.accent if is_current else kit.colors.text)
			kit.text_box(subtitle, kit.colors.dim, 12)
		}

		if date != "" {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
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
				text_color = kit.colors.faint,
				font_size = 12,
			},
			kit.to_clock_text(song.duration_seconds),
		)
	}

	return menus.apply_song_row_signal(ui.signal(row), song)
}

build_row_heart :: proc(chosen: core.Catalog_Song, is_current: bool) {
	song, state := matching.watch_match(chosen)

	if state != .Found {
		kit.icon_box(
			"",
			YOUTUBE_SYMBOL,
			13,
			kit.colors.youtube if state == .Missing else kit.colors.faint,
			{padding = {4, 4, 4, 4}},
		)
	}

	if state == .Checking do return

	persistent_id := core.app.now_playing.song.persistent_id if is_current else ""
	is_favourite := playback.is_favourite(song, persistent_id)

	if playback.build_favourite_button("heart", is_favourite) {
		playback.toggle_favourite(song, persistent_id)
	}
}
