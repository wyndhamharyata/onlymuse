package player

import "core:fmt"
import "core:slice"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:lyrics"
import "om:platform"
import "om:ui"

STAGE_COVER_POINTS :: 280

SMALL_STAGE_COVER_POINTS :: 220

// Narrower than this, the details go under the cover.
SIDE_BY_SIDE_POINTS :: 560

HERO_GAP_POINTS :: 26

// The text beside the cover takes at least this much, else the text goes under the cover.
MIN_INFO_POINTS :: 360

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

		catalog_id, phase := find_catalog_id(shown.name, shown.artist, queue_song.id if is_queue_song else "")
		path := fmt.tprintf("/v1/catalog/%s/songs/%s?include=albums,artists", apple.STOREFRONT, catalog_id) if catalog_id != "" else ""
		watched := apple.watch(path) if path != "" else apple.Watched{phase = phase}
		data, is_stale := core.find_page_data(path if path != "" else "now playing", watched.version, watched.phase)
		if is_stale && watched.phase == .Ready do read_song_details(path, data, watched.body)

		details, has_details := song_details[path]
		if !has_details || watched.phase != .Ready {
			// Until Apple answers, what Music.app gave.
			details = {song = {name = shown.name, artist_name = shown.artist, album_name = shown.album, duration_seconds = shown.duration_seconds}, album = shown.album}
			if is_queue_song do details.song = queue_song
		}

		info, _ := playback.find_track_info(shown.persistent_id)
		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width <= 0 do return

		stage := ui.box("stage", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 20})

		if ui.scope(stage) {
			set_backdrop(details.song.artwork, shown.artwork_path)
			build_hero(details, info, shown, width)
			if info.is_in_library do build_stats(details.song, info, width)
			build_detail_cards(details, info, shown.persistent_id, width)
			if watched.phase != .Ready do kit.note(kit.phase_note(watched.phase))
			build_more_by(details)
			if details.copyright != "" {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 11.5, flags = {.Wrap_Text}}, details.copyright)
			}
		}
	}
}

@(private = "file")
build_hero :: proc(details: Song_Details, info: playback.Track_Info, shown: helper.Song, width: f32) {
	cover_points: f32 = STAGE_COVER_POINTS if width >= 760 else SMALL_STAGE_COVER_POINTS
	cover_points = min(cover_points, width)
	is_side_by_side := width - cover_points - HERO_GAP_POINTS >= MIN_INFO_POINTS
	info_width := width - cover_points - HERO_GAP_POINTS if is_side_by_side else width
	hero := ui.box("hero", {width = ui.fill(), height = ui.fit_children(), axis = .X if is_side_by_side else .Y, gap = HERO_GAP_POINTS})

	if ui.scope(hero) {
		cover := ui.box("cover", {width = ui.points(cover_points), height = ui.points(cover_points)})

		if ui.scope(cover) {
			// A soft shadow below the cover, as if it floats over its colours.
			ui.box("shadow", {width = ui.points(cover_points - 24), height = ui.points(cover_points - 24), corner_radius = 24, background = {0, 0, 0, 0.75}, softness = 36, position = {12, 40}, flags = {.Floating}})
			source := apple.to_artwork_url(details.song.artwork, kit.to_artwork_pixels(cover_points))
			if source == "" do source = shown.artwork_path
			kit.artwork_box(source, cover_points, 12, kit.to_placeholder(details.song.artwork, details.album, "music.note"))
		}

		info_box := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 4})

		if ui.scope(info_box) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = to_title_size(info_width), font_weight = .Bold, padding = {0, 2, 0, 2}, flags = {.Wrap_Text}}, details.song.name)

			artist_flags := ui.Flags{.Truncate_Text}
			if details.artist_id != "" do artist_flags |= {.Clickable}
			artist := ui.box("artist", {width = ui.fill(), height = ui.fit_text(), text_color = core.app.accent if details.artist_id != "" else kit.colors.text, font_size = 20, font_weight = .Semibold, flags = artist_flags}, details.song.artist_name)
			if ui.signal(artist).is_clicked {
				core.navigate({kind = .Artist, id = details.artist_id, title = details.song.artist_name})
			}

			album_line := details.album if details.label == "" else fmt.tprintf("%s · %s", details.album, details.label)
			album_flags := ui.Flags{.Truncate_Text}
			if details.album_id != "" do album_flags |= {.Clickable}
			album := ui.box("album", {width = ui.fill(), height = ui.fit_text(), text_color = kit.to_color(0xffffffb0), font_size = 14, flags = album_flags}, album_line)
			if ui.signal(album).is_clicked do core.navigate({kind = .Album, id = details.album_id})

			build_pills(details, info)
			build_actions(details, shown.persistent_id)
			build_current_lyric(shown)
		}
	}
}

// The title keeps its two or three lines rather than filling the column with one word each.
@(private = "file")
to_title_size :: proc(info_width: f32) -> f32 {
	if info_width >= 520 do return 44
	if info_width >= 400 do return 36
	if info_width >= 260 do return 30

	return 24
}

@(private = "file")
build_pills :: proc(details: Song_Details, info: playback.Track_Info) {
	pills := make([dynamic]string, context.temp_allocator)
	rate := fmt.tprintf("%.1f kHz", f64(info.sample_rate) / 1000) if info.sample_rate > 0 else ""
	quality := ""

	if slice.contains(details.traits, "hi-res-lossless") {
		quality = "Hi-Res Lossless"
	} else if slice.contains(details.traits, "lossless") {
		quality = "Lossless"
	}
	if quality != "" {
		append(&pills, quality if rate == "" else fmt.tprintf("%s · %s", quality, rate))
	}
	if slice.contains(details.traits, "atmos") do append(&pills, "Dolby Atmos")
	if details.is_digital_master do append(&pills, "Apple Digital Master")
	if details.language != "" do append(&pills, details.language)
	if details.lyrics != "" && details.lyrics != "None" {
		append(&pills, "Word-by-word lyrics" if details.lyrics == "Word by word" else "Lyrics")
	}
	if details.is_explicit do append(&pills, "Explicit")

	if len(pills) == 0 do return

	row := ui.box("pills", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 6, padding = {0, 10, 0, 0}, flags = {.Wrap_Children}})

	if ui.scope(row) {
		for pill, index in pills {
			is_quality := index == 0 && quality != ""
			ui.box(pill, {
				width         = ui.fit_text(),
				height        = ui.points(26),
				padding       = {10, 0, 10, 0},
				corner_radius = 13,
				background    = kit.to_color(0xffffff14),
				border_width  = 1,
				border_color  = kit.to_color(0xffffff1c),
				text_color    = core.app.accent if is_quality else kit.colors.text,
				font_size     = 12,
				font_weight   = .Semibold,
			}, pill)
		}
	}
}

@(private = "file")
build_actions :: proc(details: Song_Details, persistent_id: string) {
	row := ui.box("actions", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 8, padding = {0, 12, 0, 0}, flags = {.Wrap_Children}})

	if ui.scope(row) {
		is_on := playback.is_favourite(details.song, persistent_id)
		if kit.action_button("Favourite", "heart.circle.fill" if is_on else "heart.circle", false, core.app.accent if is_on else kit.colors.text) {
			playback.toggle_favourite(details.song, persistent_id)
		}

		if details.song.id != "" && kit.action_button("Add to Playlist", "plus", false) {
			button := ui.find_box("Add to Playlist", row)
			if button != nil {
				menus.open_song_menu(details.song, {button.rect.x, button.rect.w + 4}, true)
			}
		}

		if details.url != "" && kit.action_button("Copy Link", "link", false) {
			platform.write_clipboard(details.url)
			kit.show_toast("Copied the link to the song")
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
	box := ui.box("lyric line", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2, padding = {0, 14, 0, 0}})

	if ui.scope(box) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 17, font_weight = .Semibold, flags = {.Wrap_Text}}, fmt.tprintf("♪ %s", line.text))
		if line.pronunciation != "" {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.to_color(0xffffffa0), font_size = 13, flags = {.Wrap_Text}}, line.pronunciation)
		}
	}
}

// The artist's newest release first, marked NEW for a month, then their albums.
@(private = "file")
build_more_by :: proc(details: Song_Details) {
	if details.artist_path == "" do return

	watched := apple.watch(details.artist_path)
	if watched.phase != .Ready do return

	data, is_stale := core.find_page_data(fmt.tprintf("more by %s", details.artist_path), watched.version, watched.phase)

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
				card.subtitle = to_release_note(release.attributes.release_date, now_day, allocator)
				append(&cards, card)
			}
		}
		data.cards = cards[:min(len(cards), MORE_BY_COUNT)]
	}

	if len(data.cards) == 0 do return

	shelf := ui.box("more by", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10, padding = {0, 4, 0, 0}})

	if ui.scope(shelf) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 17, font_weight = .Bold, flags = {.Truncate_Text}}, fmt.tprintf("More by %s", details.song.artist_name))
		row := ui.box("tiles", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12})

		if ui.scope(row) {
			for card, index in data.cards {
				if lists.build_card_tile(fmt.tprintf("%d %s", index, card.id), card, 118) {
					lists.open_card(data.cards, index)
				}
			}
		}
	}
}
