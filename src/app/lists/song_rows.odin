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

// Rows built past each edge of a list, so a fast scroll finds them ready.
EXTRA_ROW_COUNT :: 2

// Favourite Songs, Songs, Downloaded, every playlist and an artist's Recent Songs. With dates, the
// songs are one artist's, so each row shows its album and its date instead of the artist.
build_song_list_page :: proc(title, description: string, songs: []core.Catalog_Song, phase: apple.Phase, dates: []string = nil) {
	page := kit.page_scroll("song list")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		header := ui.box("header", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10, padding = {0, 0, 0, 0}})

		if ui.scope(header) {
			heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(heading) {
				kit.page_heading(title)
				count := fmt.tprintf("%d songs", len(songs))
				if description != "" do count = fmt.tprintf("%s · %s", count, description)
				kit.text_box(count if phase == .Ready else kit.phase_note(phase), kit.colors.dim)
			}

			if phase == .Ready && len(songs) > 0 {
				if kit.action_button("Play", "play.fill", true) do playback.play_songs(songs, 0)
				if kit.action_button("Shuffle", "shuffle", false) do playback.shuffle_songs(songs)
			}
		}

		if phase == .Ready && len(songs) == 0 do kit.note("Nothing here yet.")
		if phase == .Ready do build_song_rows(page, songs, dates)
	}
}

// Only the rows on screen are built. A click plays the list from that song.
build_song_rows :: proc(page: ^ui.Box, songs: []core.Catalog_Song, dates: []string = nil) {
	rows := ui.box("rows", {width = ui.fill(), height = ui.fit_children(), axis = .Y})
	top := core.offset_in_page(page, rows)
	first := max(0, int((page.scroll - top) / SONG_ROW_POINTS) - EXTRA_ROW_COUNT)
	last := min(len(songs) - 1, int((page.scroll - top + page.size.y) / SONG_ROW_POINTS) + EXTRA_ROW_COUNT)
	current, is_playing := playback.find_queue_song(core.app.now_playing.song.persistent_id)

	if ui.scope(rows) {
		if first > 0 do ui.box("", {width = ui.fill(), height = ui.points(f32(first) * SONG_ROW_POINTS)})

		for index in first ..= last {
			song := songs[index]
			is_current := is_playing && matching.is_same_queue_song(current, song)
			subtitle := song.album_name if dates != nil else to_song_subtitle(song)
			date := kit.to_date_text(dates[index]) if index < len(dates) else ""
			if build_song_row(fmt.tprintf("%d %s", index, song.id), song, subtitle, is_current, date) do playback.play_songs(songs, index)
		}

		if last < len(songs) - 1 do ui.box("", {width = ui.fill(), height = ui.points(f32(len(songs) - 1 - last) * SONG_ROW_POINTS)})
	}
}

// A video on YouTube has no album.
to_song_subtitle :: proc(song: core.Catalog_Song) -> string {
	return fmt.tprintf("%s · %s", song.artist_name, song.album_name) if song.album_name != "" else song.artist_name
}

// Returns true when clicked. A date, when given, sits before the heart.
build_song_row :: proc(id: string, song: core.Catalog_Song, subtitle: string, is_current: bool, date := "") -> bool {
	tint := kit.to_accent_tint(core.app.accent)
	row := ui.box(id, {
		width            = ui.fill(),
		height           = ui.points(SONG_ROW_POINTS),
		axis             = .X,
		align            = .Center,
		gap              = 11,
		padding          = {6, 0, 6, 0},
		corner_radius    = 7,
		background       = tint if is_current else {},
		hover_background = tint if is_current else kit.colors.hover,
		press_background = kit.colors.selected,
		flags            = {.Clickable},
	})

	if ui.scope(row) {
		kit.artwork_box(apple.to_artwork_url(song.artwork, kit.to_artwork_pixels(SONG_ARTWORK_POINTS)), SONG_ARTWORK_POINTS, 5, kit.to_placeholder(song.artwork, song.album_name))

		text := ui.box("", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			kit.text_box(song.name, core.app.accent if is_current else kit.colors.text)
			kit.text_box(subtitle, kit.colors.dim, 12)
		}

		if date != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 12}, date)
		build_row_heart(row, song, is_current)
		ui.box("", {width = ui.points(44), height = ui.fit_text(), text_align = .End, text_color = kit.colors.faint, font_size = 12}, kit.to_clock_text(song.duration_seconds))
	}

	return menus.track_song_row(ui.signal(row), song)
}

// Filled in the accent for a favourite, an empty outline for any other, on song lists and albums. A YouTube
// song Apple has takes the heart of Apple's song. One Apple lacks shows YouTube's mark, dim while it is checked.
build_row_heart :: proc(row: ^ui.Box, chosen: core.Catalog_Song, is_current: bool) {
	song, state := matching.find_match(chosen)

	// The same padding as the heart's button, so the lengths after it line up.
	if state != .Found do kit.icon_box("", YOUTUBE_SYMBOL, 13, kit.colors.youtube if state == .Missing else kit.colors.faint, {padding = {4, 4, 4, 4}})
	// Until Apple's catalog is checked, the song may yet be Apple's, whose heart it would take.
	if state == .Checking do return

	persistent_id := core.app.now_playing.song.persistent_id if is_current else ""
	is_on := playback.is_favourite(song, persistent_id)

	if playback.favourite_button("heart", is_on, 13) do playback.toggle_favourite(song, persistent_id)
}
