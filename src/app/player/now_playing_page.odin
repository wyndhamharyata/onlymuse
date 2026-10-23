package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:lyrics"
import "om:ui"

MAX_MORE_BY_COUNT :: 6

MORE_BY_TILE_POINTS :: 118

build_now_playing_page :: proc() {
	shown, is_song := playback.find_shown_song()
	playing, _, _ := playback.find_playing_song()
	page := kit.page_scroll("now playing")

	if ui.scope(page) {
		if !is_song {
			kit.page_heading("Now Playing")
			kit.note("Nothing is playing. Play a song and it shows here.")
			return
		}

		catalog_id, phase := watch_catalog_id(shown.name, shown.artist_name, playing.id)
		has_path := catalog_id != ""
		path :=
			fmt.tprintf("/v1/catalog/%s/songs/%s?include=albums,artists", apple.STOREFRONT, catalog_id) if has_path else ""
		watched := apple.watch(path) if has_path else apple.Watched{phase = phase}
		data, needs_read := core.find_page_data(
			path if has_path else "now playing",
			watched.version,
			watched.phase,
		)
		if needs_read do apply_song_details(path, data, watched.body)

		details, has_details := song_details[path]
		is_waiting_for_apple := !has_details || watched.phase != .Ready

		if is_waiting_for_apple {
			details = {
				song  = playing,
				album = shown.album_name,
			}
		}

		info := playback.watch_song_info(shown.persistent_id)
		width := kit.to_content_width(page)
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
			if watched.phase != .Ready do kit.build_phase(watched.phase, "the song details")
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

@(private)
build_current_lyric :: proc(shown: helper.Song) {
	phase, lines := lyrics.watch(shown.persistent_id, shown.name, shown.artist_name)
	if phase != .Ready || len(lines) == 0 do return

	position_seconds := to_lyrics_position_seconds(core.app.now_playing, lyrics_state.lead_ms)
	index := find_current_line(lines, position_seconds)
	start_lyrics_timer(lines, position_seconds)

	if index < 0 || lines[index].text == "" do return

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

@(private = "file")
build_more_by :: proc(details: Song_Details) {
	if details.artist_path == "" do return

	watched := apple.watch(details.artist_path)
	if watched.phase != .Ready do return

	data, needs_read := core.find_page_data(
		fmt.tprintf("more by %s", details.artist_path),
		watched.version,
		watched.phase,
	)

	if needs_read {
		allocator := core.page_allocator(data)
		resources := apple.to_resources(watched.body, allocator)
		if len(resources) == 0 do return

		cards := make([dynamic]apple.Card, allocator)
		seen := make(map[string]bool, context.temp_allocator)
		now_day := int(helper.now_ms() / core.DAY_MS)

		for view in ([]string{"latest-release", "full-albums"}) {
			for release in apple.read_view(resources[0], view) {
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

		data.cards = cards[:min(len(cards), MAX_MORE_BY_COUNT)]
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
		lists.build_shelf_title(fmt.tprintf("More by %s", details.song.artist_name), false)
		row := ui.box(
			"tiles",
			{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12},
		)

		if ui.scope(row) {
			for card, index in data.cards {
				if lists.build_card_tile(
					fmt.tprintf("%d %s", index, card.id),
					card,
					MORE_BY_TILE_POINTS,
				) {
					lists.open_card(data.cards, index)
				}
			}
		}
	}
}
