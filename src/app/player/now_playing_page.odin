package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:lyrics"
import "om:platform"
import "om:ui"

MORE_BY_COUNT :: 6

// The song playing: its cover large on its own blurred colours, what to do with it, what Music.app
// knows of it with you, its credits and its sound, then more by its artist.
build_now_playing_page :: proc() {
	shown, is_song := playback.find_shown_song()
	queue_song, is_queue_song := playback.find_queue_song(shown.persistent_id)
	page := kit.page_scroll("now playing")

	if ui.scope(page) {
		if !is_song {
			kit.page_heading("Now Playing")
			kit.note("Nothing is playing. Play a song and it shows here.")
			return
		}

		catalog_id, phase := find_catalog_id(
			shown.name,
			shown.artist,
			queue_song.id if is_queue_song else "",
		)
		path :=
			fmt.tprintf("/v1/catalog/%s/songs/%s?include=albums,artists", apple.STOREFRONT, catalog_id) if catalog_id != "" else ""
		watched := apple.watch(path) if path != "" else apple.Watched{phase = phase}
		data, is_stale := core.find_page_data(
			path if path != "" else "now playing",
			watched.version,
			watched.phase,
		)
		if is_stale && watched.phase == .Ready do read_song_details(path, data, watched.body)

		details, has_details := song_details[path]
		if !has_details || watched.phase != .Ready {
			// Until Apple answers, what Music.app gave.
			details = {
				song = {
					name = shown.name,
					artist_name = shown.artist,
					album_name = shown.album,
					duration_seconds = shown.duration_seconds,
				},
				album = shown.album,
			}
			if is_queue_song do details.song = queue_song
		}

		info, _ := playback.find_track_info(shown.persistent_id)
		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width <= 0 do return

		stage := ui.box(
			"stage",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 20},
		)

		if ui.scope(stage) {
			set_backdrop(details.song.artwork, shown.artwork_path)
			build_hero(details, info, shown, width)
			if info.is_in_library do build_stats(details.song, info, width)
			build_detail_cards(details, info, shown.persistent_id, width)
			if watched.phase != .Ready do kit.note(kit.phase_note(watched.phase))
			build_more_by(details)
			if details.copyright != "" {
				ui.box(
					"",
					{
						width = ui.fill(),
						height = ui.fit_text(),
						text_color = kit.colors.faint,
						font_size = 11.5,
						flags = {.Wrap_Text},
					},
					details.copyright,
				)
			}
		}
	}
}

// The line being sung, with its romaji, from the lyrics the panel loads.
@(private)
build_current_lyric :: proc(shown: helper.Song) {
	phase, lines := lyrics.find(shown.persistent_id, shown.name, shown.artist)
	if phase != .Ready || len(lines) == 0 do return

	position := helper.position_seconds(core.app.now_playing) + f64(lyrics_state.lead_ms) / 1000
	index := find_current_line(lines, position)
	if next := find_next_change(lines, position); next >= 0 {
		platform.request_frame_after(next - position + WORD_TIMER_SLACK_SECONDS)
	}
	if index < 0 || index >= len(lines) || lines[index].text == "" do return

	line := lines[index]
	box := ui.box(
		"lyric line",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .Y,
			gap = 2,
			padding = {0, 14, 0, 0},
		},
	)

	if ui.scope(box) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = 17,
				font_weight = .Semibold,
				flags = {.Wrap_Text},
			},
			fmt.tprintf("♪ %s", line.text),
		)
		if line.pronunciation != "" {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.to_color(0xffffffa0),
					font_size = 13,
					flags = {.Wrap_Text},
				},
				line.pronunciation,
			)
		}
	}
}

// The artist's newest release first, marked NEW for a month, then their albums.
@(private = "file")
build_more_by :: proc(details: Song_Details) {
	if details.artist_path == "" do return

	watched := apple.watch(details.artist_path)
	if watched.phase != .Ready do return

	data, is_stale := core.find_page_data(
		fmt.tprintf("more by %s", details.artist_path),
		watched.version,
		watched.phase,
	)

	if is_stale {
		allocator := core.page_allocator(data)
		resources := apple.to_resources(watched.body, allocator)
		if len(resources) == 0 do return

		cards := make([dynamic]apple.Card, allocator)
		seen := make(map[string]bool, context.temp_allocator)
		now_day := int(helper.now_ms() / 86_400_000)

		for view in ([]string{"latest-release", "full-albums"}) {
			for release in apple.list_view(resources[0], view) {
				if seen[release.id] || release.attributes.name == details.album do continue
				seen[release.id] = true

				card := apple.to_card(release)
				card.subtitle = to_release_note(
					release.attributes.release_date,
					now_day,
					allocator,
				)
				append(&cards, card)
			}
		}
		data.cards = cards[:min(len(cards), MORE_BY_COUNT)]
	}

	if len(data.cards) == 0 do return

	shelf := ui.box(
		"more by",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .Y,
			gap = 10,
			padding = {0, 4, 0, 0},
		},
	)

	if ui.scope(shelf) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = 17,
				font_weight = .Bold,
				flags = {.Truncate_Text},
			},
			fmt.tprintf("More by %s", details.song.artist_name),
		)
		row := ui.box(
			"tiles",
			{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12},
		)

		if ui.scope(row) {
			for card, index in data.cards {
				if lists.build_card_tile(fmt.tprintf("%d %s", index, card.id), card, 118) {
					lists.open_card(data.cards, index)
				}
			}
		}
	}
}
