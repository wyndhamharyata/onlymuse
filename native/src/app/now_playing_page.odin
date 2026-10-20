package app

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:apple"
import "om:helper"
import "om:image"
import "om:lyrics"
import "om:platform"
import "om:render"
import "om:ui"

STAGE_COVER_POINTS :: 280
SMALL_STAGE_COVER_POINTS :: 220
// Narrower than this, the details go under the cover.
SIDE_BY_SIDE_POINTS :: 560
BACKDROP_POINTS :: 520
// The cover is drawn this small and stretched for the backdrop: a blur with no blur.
BACKDROP_PIXELS :: 24
STAT_WEEKS :: 8
MORE_BY_COUNT :: 6
// A release this recent is marked NEW.
NEW_RELEASE_DAYS :: 30

@(private = "file")
Detail :: struct {
	label, value: string,
}

@(private = "file")
Release :: struct {
	card:   apple.Card,
	is_new: bool,
}

@(private = "file")
Song_Details :: struct {
	song:                                    Catalog_Song,
	album, kind, copyright, url:             string,
	artist_id, album_id, artist_path:        string,
	composer, genre, released, label, isrc:  string,
	language, lyrics:                        string,
	traits:                                  []string,
	is_digital_master, is_explicit:          bool,
}

@(private = "file")
song_details: map[string]Song_Details

// The song playing: its cover large on its own blurred colours, what to do with it, what Music.app
// knows of it with you, its credits and its sound, then more by its artist.
build_now_playing_page :: proc() {
	shown, is_song := find_shown_song()
	queue_song, is_queue_song := find_queue_song(shown.persistent_id)
	page := page_scroll("now playing")

	if ui.scope(page) {
		if !is_song {
			page_heading("Now Playing")
			note("Nothing is playing. Play a song and it shows here.")
			return
		}

		catalog_id, phase := find_catalog_id(shown.name, shown.artist, queue_song.id if is_queue_song else "")
		path := fmt.tprintf("/v1/catalog/%s/songs/%s?include=albums,artists", apple.STOREFRONT, catalog_id) if catalog_id != "" else ""
		watched := apple.watch(path) if path != "" else apple.Watched{phase = phase}
		data, is_stale := find_page_data(path if path != "" else "now playing", watched.version, watched.phase)
		if is_stale && watched.phase == .Ready do read_song_details(path, data, watched.body)

		details, has_details := song_details[path]
		if !has_details || watched.phase != .Ready {
			// Until Apple answers, what Music.app gave.
			details = {song = {name = shown.name, artist_name = shown.artist, album_name = shown.album, duration_seconds = shown.duration_seconds}, album = shown.album}
			if is_queue_song do details.song = queue_song
		}

		info, _ := find_track_info(shown.persistent_id)
		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width <= 0 do return

		stage := ui.box("stage", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 20})

		if ui.scope(stage) {
			set_backdrop(details.song.artwork, shown.artwork_path)
			build_hero(details, info, shown, width)
			if info.is_in_library do build_stats(details.song, info)
			build_detail_cards(details, info, shown.persistent_id, width)
			if watched.phase != .Ready do note(phase_note(watched.phase))
			build_more_by(details)
			if details.copyright != "" do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11.5, flags = {.Wrap_Text}}, details.copyright)
		}
	}
}

// ---- The backdrop and the hero ----

@(private = "file")
Backdrop_Paint :: struct {
	source: string,
}

@(private = "file")
draw_backdrop :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Backdrop_Paint)box.data
	texture, image_opacity := image.find(paint.source, BACKDROP_PIXELS)
	if texture == nil do return

	// The square cover covers the wide box: the middle band of it shows.
	aspect := (rect.w - rect.y) / max(1, rect.z - rect.x)
	uv := [4]f32{0, 0.5 - aspect / 2, 1, 0.5 + aspect / 2}
	alpha := 0.6 * opacity * image_opacity
	render.push({rect = rect, uv = uv, color = {0.62, 0.62, 0.62, alpha}, gradient = {0.25, 1}, clip = clip, kind = .Image}, texture)
}

// The cover the page area spreads behind its toolbar and the page, as of the last frame Now Playing was built.
@(private = "file")
backdrop_source: string

@(private = "file")
set_backdrop :: proc(artwork: apple.Artwork, artwork_path: string) {
	source := apple.to_artwork_url(artwork, BACKDROP_PIXELS)
	if source == "" do source = artwork_path
	if source == backdrop_source do return

	delete(backdrop_source)
	backdrop_source = strings.clone(source)
}

// Called by the page area before its toolbar, so the toolbar sits on it too. It stays as the page scrolls.
build_page_backdrop :: proc() {
	if current_page().kind != .Now_Playing || backdrop_source == "" do return

	box := ui.box("backdrop", {width = ui.fill(), height = ui.points(BACKDROP_POINTS), position = {0, 0}, flags = {.Floating}})
	paint := new(Backdrop_Paint, context.temp_allocator)
	paint.source = backdrop_source
	box.draw = draw_backdrop
	box.data = paint
}

@(private = "file")
build_hero :: proc(details: Song_Details, info: Track_Info, shown: helper.Song, width: f32) {
	is_side_by_side := width >= SIDE_BY_SIDE_POINTS
	cover_points: f32 = STAGE_COVER_POINTS if width >= 760 else SMALL_STAGE_COVER_POINTS
	hero := ui.box("hero", {width = ui.fill(), height = ui.fit_children(), axis = .X if is_side_by_side else .Y, align = .End if is_side_by_side else .Start, gap = 26})

	if ui.scope(hero) {
		cover := ui.box("cover", {width = ui.points(cover_points), height = ui.points(cover_points)})

		if ui.scope(cover) {
			// A soft shadow below the cover, as if it floats over its colours.
			ui.box("shadow", {width = ui.points(cover_points - 24), height = ui.points(cover_points - 24), corner_radius = 24, background = {0, 0, 0, 0.75}, softness = 36, position = {12, 40}, flags = {.Floating}})
			source := apple.to_artwork_url(details.song.artwork, to_artwork_pixels(cover_points))
			if source == "" do source = shown.artwork_path
			artwork_box(source, cover_points, 12, to_placeholder(details.song.artwork, details.album, "music.note"))
		}

		info_box := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 4})

		if ui.scope(info_box) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = to_color(0xffffffb0), font_size = 11.5, font_weight = .Bold}, to_eyebrow(details))
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 44, font_weight = .Bold, padding = {0, 2, 0, 2}, flags = {.Wrap_Text}}, details.song.name)

			artist := ui.box("artist", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent if details.artist_id != "" else colors.text, font_size = 20, font_weight = .Semibold, flags = {.Clickable} if details.artist_id != "" else {}}, details.song.artist_name)
			if ui.signal(artist).is_clicked do navigate({kind = .Artist, id = details.artist_id, title = details.song.artist_name})

			album_line := details.album if details.label == "" else fmt.tprintf("%s · %s", details.album, details.label)
			album := ui.box("album", {width = ui.fit_text(), height = ui.fit_text(), text_color = to_color(0xffffffb0), font_size = 14, flags = {.Clickable} if details.album_id != "" else {}}, album_line)
			if ui.signal(album).is_clicked do navigate({kind = .Album, id = details.album_id})

			build_pills(details, info)
			build_actions(details, shown.persistent_id)
			build_lyric_line(shown)
		}
	}
}

// "NOW PLAYING · SINGLE · 2026".
@(private = "file")
to_eyebrow :: proc(details: Song_Details) -> string {
	kind := "ALBUM"
	if strings.has_suffix(details.album, " - Single") do kind = "SINGLE"
	if strings.has_suffix(details.album, " - EP") do kind = "EP"
	if details.released == "" do return fmt.tprintf("NOW PLAYING · %s", kind)

	return fmt.tprintf("NOW PLAYING · %s · %s", kind, details.released[max(0, len(details.released) - 4):])
}

@(private = "file")
build_pills :: proc(details: Song_Details, info: Track_Info) {
	pills := make([dynamic]string, context.temp_allocator)
	rate := fmt.tprintf("%.1f kHz", f64(info.sample_rate) / 1000) if info.sample_rate > 0 else ""
	quality := ""

	if slice.contains(details.traits, "hi-res-lossless") {
		quality = "Hi-Res Lossless"
	} else if slice.contains(details.traits, "lossless") {
		quality = "Lossless"
	}
	if quality != "" do append(&pills, quality if rate == "" else fmt.tprintf("%s · %s", quality, rate))
	if slice.contains(details.traits, "atmos") do append(&pills, "Dolby Atmos")
	if details.is_digital_master do append(&pills, "Apple Digital Master")
	if details.language != "" do append(&pills, details.language)
	if details.lyrics != "" && details.lyrics != "None" do append(&pills, "Word-by-word lyrics" if details.lyrics == "Word by word" else "Lyrics")
	if details.is_explicit do append(&pills, "Explicit")

	if len(pills) == 0 do return

	row := ui.box("pills", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 6, padding = {0, 10, 0, 0}})

	if ui.scope(row) {
		for pill, index in pills {
			is_quality := index == 0 && quality != ""
			ui.box(pill, {
				width         = ui.fit_text(),
				height        = ui.points(26),
				padding       = {10, 0, 10, 0},
				corner_radius = 13,
				background    = to_color(0xffffff14),
				border_width  = 1,
				border_color  = to_color(0xffffff1c),
				text_color    = app.accent if is_quality else colors.text,
				font_size     = 12,
				font_weight   = .Semibold,
			}, pill)
		}
	}
}

@(private = "file")
build_actions :: proc(details: Song_Details, persistent_id: string) {
	row := ui.box("actions", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 8, padding = {0, 12, 0, 0}})

	if ui.scope(row) {
		is_on := is_favourite(details.song, persistent_id)
		if action_button("Favourite", "heart.fill" if is_on else "heart", false, app.accent if is_on else colors.text) do toggle_favourite(details.song, persistent_id)

		if details.song.id != "" && action_button("Add to Playlist", "plus", false) {
			button := ui.find_box("Add to Playlist", row)
			if button != nil do open_song_menu(details.song, {button.rect.x, button.rect.w + 4}, true)
		}

		if details.url != "" && action_button("Copy Link", "link", false) {
			platform.write_clipboard(details.url)
			show_toast("Copied the link to the song")
		}
	}
}

// The line being sung, with its romaji, from the lyrics the panel loads.
@(private = "file")
build_lyric_line :: proc(shown: helper.Song) {
	phase, lines := lyrics.find(shown.persistent_id, shown.name, shown.artist)
	if phase != .Ready || len(lines) == 0 do return

	position := helper.position_seconds(app.now_playing) + f64(lyrics_state.lead_ms) / 1000
	index := find_current_line(lines, position)
	if next := find_next_change(lines, position); next >= 0 do platform.request_frame_after(next - position + WORD_TIMER_SLACK_SECONDS)
	if index < 0 || index >= len(lines) || lines[index].text == "" do return

	line := lines[index]
	box := ui.box("lyric line", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2, padding = {0, 14, 0, 0}})

	if ui.scope(box) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Semibold, flags = {.Wrap_Text}}, fmt.tprintf("♪ %s", line.text))
		if line.pronunciation != "" do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = to_color(0xffffffa0), font_size = 13, flags = {.Wrap_Text}}, line.pronunciation)
	}
}

// ---- What Music.app knows ----

@(private = "file")
build_stats :: proc(song: Catalog_Song, info: Track_Info) {
	row := ui.box("stats", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 10})

	if ui.scope(row) {
		weeks, rank := count_weekly_plays(song)
		plays := build_stat_card("plays", "PLAYS", fmt.tprintf("%d", info.played_count), fmt.tprintf("#%d this month", rank) if rank > 0 else "", 1.4)
		if ui.scope(plays) do build_spark(weeks)

		last := info.played_date_ms
		build_stat_card("last played", "LAST PLAYED", to_day_text(last) if last > 0 else "Never", platform.format_date(last, "HH:mm") if last > 0 else "")

		added := info.date_added_ms
		build_stat_card("added", "IN LIBRARY SINCE", platform.format_date(added, "d MMM") if added > 0 else "—", platform.format_date(added, "yyyy") if added > 0 else "")

		skipped := info.skipped_date_ms
		build_stat_card("skips", "SKIPS", fmt.tprintf("%d", info.skipped_count), fmt.tprintf("last on %s", platform.format_date(skipped, "d MMM")) if skipped > 0 else "")
	}
}

@(private = "file")
build_stat_card :: proc(id, label, value, note_text: string, weight: f32 = 1) -> ^ui.Box {
	card := ui.box(id, {width = ui.fill(weight), height = ui.fit_children(), axis = .X, align = .End, padding = {14, 12, 14, 12}, corner_radius = 10, background = to_color(0xffffff0a), border_width = 1, border_color = to_color(0xffffff10)})

	if ui.scope(card) {
		column := ui.box("text", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 1})

		if ui.scope(column) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11, font_weight = .Semibold}, label)
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 24, font_weight = .Bold, flags = {.Truncate_Text}}, value)
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, font_size = 12, flags = {.Truncate_Text}}, note_text)
		}
	}

	return card
}

// This song's plays in each of the last 8 weeks, oldest first, from the app's own log, and its rank
// among the songs played in the last 30 days, 0 when it has none.
@(private = "file")
count_weekly_plays :: proc(song: Catalog_Song) -> (weeks: [STAT_WEEKS]int, rank: int) {
	now := i64(helper.now_ms())
	week_ms: i64 = 7 * 86_400_000
	month_start := now - 30 * 86_400_000
	counts := make(map[string]int, context.temp_allocator)
	own := 0

	for play in play_log {
		if play.is_skip do continue

		if is_same_song(play, song) {
			age := int((now - play.played_at) / week_ms)
			if age < STAT_WEEKS do weeks[STAT_WEEKS - 1 - age] += 1
		}

		if play.played_at >= month_start {
			key := fmt.tprintf("%s\x1f%s", play.name, play.artist)
			counts[key] += 1
			if is_same_song(play, song) do own = counts[key]
		}
	}

	if own == 0 do return weeks, 0

	rank = 1
	for _, count in counts do if count > own do rank += 1

	return weeks, rank
}

@(private = "file")
build_spark :: proc(weeks: [STAT_WEEKS]int) {
	most := 1
	for count in weeks do most = max(most, count)

	spark := ui.box("spark", {width = ui.points(120), height = ui.points(30), axis = .X, align = .End, gap = 3})

	if ui.scope(spark) {
		for count, index in weeks {
			height := max(3, 30 * f32(count) / f32(most))
			ui.box(fmt.tprintf("week %d", index), {width = ui.fill(), height = ui.points(height), corner_radius = 2, background = {app.accent.r, app.accent.g, app.accent.b, 0.75 if count > 0 else 0.2}})
		}
	}
}

// "Today", "Yesterday" or "3 Oct", by local day.
@(private = "file")
to_day_text :: proc(unix_ms: f64) -> string {
	offset := f64(platform.local_offset_seconds())
	to_day :: proc(ms, offset: f64) -> int {return int(math.floor((ms / 1000 + offset) / 86_400))}
	days := to_day(helper.now_ms(), offset) - to_day(unix_ms, offset)

	switch days {
	case 0:
		return "Today"
	case 1:
		return "Yesterday"
	}

	return platform.format_date(unix_ms, "d MMM")
}

// ---- Credits and sound ----

@(private = "file")
build_detail_cards :: proc(details: Song_Details, info: Track_Info, persistent_id: string, width: f32) {
	row := ui.box("details", {width = ui.fill(), height = ui.fit_children(), axis = .X if width >= SIDE_BY_SIDE_POINTS else .Y, gap = 10})

	if ui.scope(row) {
		credits := make([dynamic]Detail, context.temp_allocator)
		append(&credits, Detail{"Performed by", details.song.artist_name})
		if details.composer != "" do append(&credits, Detail{"Composed by", details.composer})
		if writers := lyrics.find_songwriters(persistent_id); len(writers) > 0 do append(&credits, Detail{"Lyrics by", strings.join(writers, ", ", context.temp_allocator)})
		if details.label != "" do append(&credits, Detail{"Label", details.label})
		if details.released != "" do append(&credits, Detail{"Released", details.released})
		if details.genre != "" do append(&credits, Detail{"Genre", details.genre})
		build_detail_card("credits", "CREDITS", credits[:], 1.1)

		sound := make([dynamic]Detail, context.temp_allocator)
		if format := to_format(details, info); format != "" do append(&sound, Detail{"Format", format})
		rates := make([dynamic]string, context.temp_allocator)
		if info.sample_rate > 0 do append(&rates, fmt.tprintf("%.1f kHz", f64(info.sample_rate) / 1000))
		if info.bit_rate > 0 do append(&rates, fmt.tprintf("%d kbps", info.bit_rate))
		if len(rates) > 0 do append(&sound, Detail{"Sample rate · bit rate" if len(rates) == 2 else "Sample rate" if info.sample_rate > 0 else "Bit rate", strings.join(rates[:], " · ", context.temp_allocator)})
		length := to_clock_text(details.song.duration_seconds)
		append(&sound, Detail{"Length · BPM" if info.bpm > 0 else "Length", fmt.tprintf("%s · %d", length, info.bpm) if info.bpm > 0 else length})
		if info.size > 0 do append(&sound, Detail{"Size", fmt.tprintf("%.1f MB", info.size / 1_000_000)})
		if details.isrc != "" do append(&sound, Detail{"ISRC", details.isrc})
		build_detail_card("sound", "SOUND", sound[:], 1)
	}
}

// Music.app names a streamed song "HLS media", so Apple's traits say what it streams.
@(private = "file")
to_format :: proc(details: Song_Details, info: Track_Info) -> string {
	is_lossless := slice.contains(details.traits, "lossless")

	switch {
	case info.kind == "HLS media" || info.kind == "":
		if len(details.traits) == 0 do return ""
		return "Apple Lossless, streamed" if is_lossless else "AAC, streamed"
	case strings.contains(info.kind, "Lossless"):
		return "Apple Lossless (ALAC)"
	case strings.contains(info.kind, "AAC"):
		return "AAC"
	}

	return info.kind
}

@(private = "file")
build_detail_card :: proc(id, title: string, rows: []Detail, weight: f32) {
	card := ui.box(id, {width = ui.fill(weight), height = ui.fit_children(), axis = .Y, gap = 6, padding = {16, 14, 16, 14}, corner_radius = 10, background = to_color(0xffffff0a), border_width = 1, border_color = to_color(0xffffff10)})

	if ui.scope(card) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11, font_weight = .Semibold, padding = {0, 0, 0, 4}}, title)

		for row in rows {
			line := ui.box(row.label, {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12})

			if ui.scope(line) {
				ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.dim, font_size = 13}, row.label)
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 13, text_align = .End, flags = {.Truncate_Text}}, row.value)

				if row.label == "ISRC" {
					if icon_button("copy isrc", "doc.on.doc", 11, colors.dim) {
						platform.write_clipboard(row.value)
						show_toast("Copied the ISRC")
					}
				}
			}
		}
	}
}

// ---- More by the artist ----

// The artist's newest release first, marked NEW for a month, then their albums.
@(private = "file")
build_more_by :: proc(details: Song_Details) {
	if details.artist_path == "" do return

	watched := apple.watch(details.artist_path)
	if watched.phase != .Ready do return

	data, is_stale := find_page_data(fmt.tprintf("more by %s", details.artist_path), watched.version, watched.phase)

	if is_stale {
		allocator := page_allocator(data)
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
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, fmt.tprintf("More by %s", details.song.artist_name))
		row := ui.box("tiles", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12})

		if ui.scope(row) {
			for card, index in data.cards {
				if build_card_tile(fmt.tprintf("%d %s", index, card.id), card, 118) do open_card(data.cards, index)
			}
		}
	}
}

// "NEW · 17 Oct" for a release this month, else its year.
@(private = "file")
to_release_note :: proc(date: string, now_day: int, allocator := context.allocator) -> string {
	if len(date) < 10 do return ""

	year, _ := strconv.parse_int(date[:4])
	month, _ := strconv.parse_int(date[5:7])
	day, _ := strconv.parse_int(date[8:10])
	release, ok := time.datetime_to_time(year, month, day, 0, 0, 0)
	if !ok do return date[:4]

	release_day := int(time.to_unix_seconds(release) / 86_400)
	if now_day - release_day <= NEW_RELEASE_DAYS && now_day >= release_day {
		return fmt.aprintf("NEW · %s", platform.format_date(f64(time.to_unix_seconds(release)) * 1000, "d MMM"), allocator = allocator)
	}

	return strings.clone(date[:4], allocator)
}

// ---- Apple's song ----

// A queue song brings its catalog ID. Any other is found by its name and artist, as Music.app gives only those.
@(private = "file")
find_catalog_id :: proc(name, artist, queue_id: string) -> (string, apple.Phase) {
	if is_catalog_id(queue_id) do return queue_id, .Ready

	term := to_query_text(fmt.tprintf("%s %s", name, artist))
	watched := apple.watch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=10", apple.STOREFRONT, term))
	if watched.phase != .Ready do return "", watched.phase

	Search_Answer :: struct {
		results: struct {
			songs: apple.Related,
		},
	}
	answer: Search_Answer
	_ = unmarshal_text(watched.body, &answer)
	songs := answer.results.songs.data
	if len(songs) == 0 do return "", .Failed

	for found in songs {
		if found.attributes.name == name && found.attributes.artist_name == artist do return strings.clone(found.id, context.temp_allocator), .Ready
	}

	return strings.clone(songs[0].id, context.temp_allocator), .Ready
}

// Catalog IDs are digits. A song uploaded from a Mac has only a library ID.
@(private = "file")
is_catalog_id :: proc(id: string) -> bool {
	if id == "" do return false
	for character in id do if character < '0' || character > '9' do return false

	return true
}

@(private = "file")
read_song_details :: proc(path: string, data: ^Page_Data, body: string) {
	allocator := page_allocator(data)
	resources := apple.to_resources(body, allocator)
	if len(resources) == 0 do return

	song := resources[0]
	attributes := song.attributes
	albums := apple.list_related(song, "albums")
	artists := apple.list_related(song, "artists")
	album := albums[0].attributes if len(albums) > 0 else {}
	artist_id := artists[0].id if len(artists) > 0 else ""

	details := Song_Details {
		song              = apple.to_catalog_song(song),
		album             = attributes.album_name,
		copyright         = album.copyright,
		url               = attributes.url,
		artist_id         = artist_id,
		album_id          = albums[0].id if len(albums) > 0 else "",
		composer          = attributes.composer_name,
		genre             = strings.join(attributes.genre_names, ", ", allocator),
		released          = to_date_text(attributes.release_date, allocator),
		label             = album.record_label,
		isrc              = attributes.isrc,
		language          = to_language_name(attributes.audio_locale),
		lyrics            = "Word by word" if attributes.has_time_synced_lyrics else "Yes" if attributes.has_lyrics else "None",
		traits            = attributes.audio_traits,
		is_digital_master = attributes.is_apple_digital_master,
		is_explicit       = attributes.content_rating == "explicit",
	}
	// The artist page asks for these views, so the answer is shared.
	if artist_id != "" do details.artist_path = fmt.aprintf("/v1/catalog/%s/artists/%s?views=top-songs,latest-release,full-albums,similar-artists", apple.STOREFRONT, artist_id, allocator = allocator)

	// Keyed by the page's path, which names the song. The strings live in the page's arena, read again with it.
	if path in song_details {
		song_details[path] = details
	} else {
		song_details[strings.clone(path)] = details
	}
}

// "2021-03-03" as "3 March 2021".
@(private = "file")
to_date_text :: proc(date: string, allocator := context.allocator) -> string {
	if len(date) < 10 do return date

	month_names := [?]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	month, month_ok := strconv.parse_int(date[5:7])
	day, day_ok := strconv.parse_int(date[8:10])
	if !month_ok || !day_ok || month < 1 || month > 12 do return date

	return fmt.aprintf("%d %s %s", day, month_names[month - 1], date[:4], allocator = allocator)
}

// Apple's locale codes, as "ja" or "en-US", named for the languages in this library. Others show as the code.
@(private = "file")
to_language_name :: proc(locale: string) -> string {
	names := [][2]string{{"en", "English"}, {"ja", "Japanese"}, {"ko", "Korean"}, {"zh", "Chinese"}, {"id", "Indonesian"}, {"es", "Spanish"}, {"fr", "French"}, {"de", "German"}, {"it", "Italian"}, {"pt", "Portuguese"}, {"zxx", ""}}
	language := locale
	if dash := strings.index_byte(locale, '-'); dash > 0 do language = locale[:dash]

	for name in names do if name[0] == language do return name[1]

	return locale
}
