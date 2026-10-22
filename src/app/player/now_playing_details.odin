package player

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:app/playback"
import "om:apple"
import "om:lyrics"
import "om:platform"
import "om:ui"

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

@(private)
Song_Details :: struct {
	song:                                    core.Catalog_Song,
	album, kind, copyright, url:             string,
	artist_id, album_id, artist_path:        string,
	composer, genre, released, label, isrc:  string,
	language, lyrics:                        string,
	traits:                                  []string,
	is_digital_master, is_explicit:          bool,
}

@(private)
song_details: map[string]Song_Details

@(private)
build_detail_cards :: proc(details: Song_Details, info: playback.Track_Info, persistent_id: string, width: f32) {
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
		length := kit.to_clock_text(details.song.duration_seconds)
		append(&sound, Detail{"Length · BPM" if info.bpm > 0 else "Length", fmt.tprintf("%s · %d", length, info.bpm) if info.bpm > 0 else length})
		if info.size > 0 do append(&sound, Detail{"Size", fmt.tprintf("%.1f MB", info.size / 1_000_000)})
		if details.isrc != "" do append(&sound, Detail{"ISRC", details.isrc})
		build_detail_card("sound", "SOUND", sound[:], 1)
	}
}

// Music.app names a streamed song "HLS media", so Apple's traits say what it streams.
@(private = "file")
to_format :: proc(details: Song_Details, info: playback.Track_Info) -> string {
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
	card := ui.box(id, {width = ui.fill(weight), height = ui.fit_children(), axis = .Y, gap = 6, padding = {16, 14, 16, 14}, corner_radius = 10, background = kit.to_color(0xffffff0a), border_width = 1, border_color = kit.to_color(0xffffff10)})

	if ui.scope(card) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 11, font_weight = .Semibold, padding = {0, 0, 0, 4}}, title)

		for row in rows {
			line := ui.box(row.label, {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12})

			if ui.scope(line) {
				ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = kit.colors.dim, font_size = 13}, row.label)
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 13, text_align = .End, flags = {.Truncate_Text}}, row.value)

				if row.label == "ISRC" {
					if kit.icon_button("copy isrc", "doc.on.doc", 11, kit.colors.dim) {
						platform.write_clipboard(row.value)
						kit.show_toast("Copied the ISRC")
					}
				}
			}
		}
	}
}

// "NEW · 17 Oct" for a release this month, else its year.
@(private)
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

// A queue song brings its catalog ID. Any other is found by its name and artist, as Music.app gives only those.
@(private)
find_catalog_id :: proc(name, artist, queue_id: string) -> (string, apple.Phase) {
	if matching.is_catalog_id(queue_id) do return queue_id, .Ready

	term := apple.to_query_text(fmt.tprintf("%s %s", name, artist))
	watched := apple.watch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=10", apple.STOREFRONT, term))
	if watched.phase != .Ready do return "", watched.phase

	Search_Answer :: struct {
		results: struct {
			songs: apple.Related,
		},
	}
	answer: Search_Answer
	_ = core.unmarshal_text(watched.body, &answer)
	songs := answer.results.songs.data
	if len(songs) == 0 do return "", .Failed

	for found in songs {
		if found.attributes.name == name && found.attributes.artist_name == artist do return strings.clone(found.id, context.temp_allocator), .Ready
	}

	return strings.clone(songs[0].id, context.temp_allocator), .Ready
}

@(private)
read_song_details :: proc(path: string, data: ^core.Page_Data, body: string) {
	allocator := core.page_allocator(data)
	resources := apple.to_resources(body, allocator)

	// The old details point into the arena find_page_data just reset.
	if len(resources) == 0 {
		// delete_key hands back the map's own copy of the key, which is the one to free.
		stored_path, _ := delete_key(&song_details, path)
		delete(stored_path)
		return
	}

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
