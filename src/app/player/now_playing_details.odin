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

NEW_RELEASE_DAYS :: 30

@(private = "file")
Detail :: struct {
	label, value: string,
	is_copyable:  bool,
}

@(private)
Lyrics_Kind :: enum {
	None,
	Plain,
	Word_By_Word,
}

@(private)
Song_Details :: struct {
	song:                                   core.Catalog_Song,
	album, copyright, url:                  string,
	artist_id, album_id, artist_path:       string,
	composer, genre, released, label, isrc: string,
	language:                               string,
	lyrics:                                 Lyrics_Kind,
	traits:                                 []string,
	is_digital_master, is_explicit:         bool,
}

@(private)
to_sample_rate_text :: proc(sample_rate_hz: int) -> string {
	return fmt.tprintf("%.1f kHz", f64(sample_rate_hz) / 1000)
}

@(private)
song_details: map[string]Song_Details

@(private)
build_detail_cards :: proc(
	details: Song_Details,
	info: playback.Song_Info,
	persistent_id: string,
	width: f32,
) {
	row := ui.box(
		"details",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .X if width >= SIDE_BY_SIDE_POINTS else .Y,
			gap = 10,
		},
	)

	if ui.scope(row) {
		credits := make([dynamic]Detail, context.temp_allocator)
		append(&credits, Detail{"Performed by", details.song.artist_name, false})
		if details.composer != "" do append(&credits, Detail{"Composed by", details.composer, false})

		if writers := lyrics.list_songwriters(persistent_id); len(writers) > 0 {
			writer_text := strings.join(writers, ", ", context.temp_allocator)
			append(&credits, Detail{"Lyrics by", writer_text, false})
		}

		if details.label != "" do append(&credits, Detail{"Label", details.label, false})
		if details.released != "" do append(&credits, Detail{"Released", details.released, false})
		if details.genre != "" do append(&credits, Detail{"Genre", details.genre, false})
		build_detail_card("credits", "CREDITS", credits[:], 1.1)
		build_detail_card("sound", "SOUND", list_sound_details(details, info), 1)
	}
}

@(private = "file")
list_sound_details :: proc(details: Song_Details, info: playback.Song_Info) -> []Detail {
	sound := make([dynamic]Detail, context.temp_allocator)
	has_sample_rate := info.sample_rate_hz > 0
	has_bit_rate := info.bit_rate_kbps > 0
	sample_rate := to_sample_rate_text(info.sample_rate_hz)
	bit_rate := fmt.tprintf("%d kbps", info.bit_rate_kbps)
	length := kit.to_clock_text(details.song.duration_seconds)

	if format := to_format(details, info); format != "" {
		append(&sound, Detail{"Format", format, false})
	}

	if has_sample_rate && has_bit_rate {
		rates := fmt.tprintf("%s · %s", sample_rate, bit_rate)
		append(&sound, Detail{"Sample rate · bit rate", rates, false})
	} else if has_sample_rate {
		append(&sound, Detail{"Sample rate", sample_rate, false})
	} else if has_bit_rate {
		append(&sound, Detail{"Bit rate", bit_rate, false})
	}

	if info.bpm > 0 {
		append(&sound, Detail{"Length · BPM", fmt.tprintf("%s · %d", length, info.bpm), false})
	} else {
		append(&sound, Detail{"Length", length, false})
	}

	if info.size_bytes > 0 {
		size := fmt.tprintf("%.1f MB", info.size_bytes / 1_000_000)
		append(&sound, Detail{"Size", size, false})
	}

	if details.isrc != "" do append(&sound, Detail{"ISRC", details.isrc, true})

	return sound[:]
}

// Music.app names a streamed song "HLS media", so Apple's traits say what it streams.
@(private = "file")
to_format :: proc(details: Song_Details, info: playback.Song_Info) -> string {
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
	card := ui.box(
		id,
		{
			width = ui.fill(weight),
			height = ui.fit_children(),
			axis = .Y,
			gap = 6,
			padding = {16, 14, 16, 14},
			corner_radius = 10,
			background = kit.colors.detail_card,
			border_width = 1,
			border_color = kit.colors.detail_card_border,
		},
	)

	if ui.scope(card) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.faint,
				font_size = 11,
				font_weight = .Semibold,
				padding = {0, 0, 0, 4},
			},
			title,
		)

		for row in rows {
			line := ui.box(
				row.label,
				{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12},
			)

			if ui.scope(line) {
				ui.box(
					"",
					{
						width = ui.fit_text(),
						height = ui.fit_text(),
						text_color = kit.colors.dim,
						font_size = 13,
					},
					row.label,
				)
				ui.box(
					"",
					{
						width = ui.fill(),
						height = ui.fit_text(),
						text_color = kit.colors.text,
						font_size = 13,
						text_align = .End,
						flags = {.Truncate_Text},
					},
					row.value,
				)

				if row.is_copyable && kit.icon_button("copy", "doc.on.doc", 11, kit.colors.dim) {
					platform.set_clipboard(row.value)
					kit.show_toast(fmt.tprintf("Copied the %s", row.label))
				}
			}
		}
	}
}

@(private)
to_release_note :: proc(date: string, now_day: int, allocator := context.allocator) -> string {
	if len(date) < 10 do return ""

	year, _ := strconv.parse_int(date[:4])
	month, _ := strconv.parse_int(date[5:7])
	day, _ := strconv.parse_int(date[8:10])
	release, is_date := time.datetime_to_time(year, month, day, 0, 0, 0)
	if !is_date do return date[:4]

	release_day := int(time.to_unix_seconds(release) / core.DAY_SECONDS)
	is_new := now_day - release_day <= NEW_RELEASE_DAYS && now_day >= release_day

	if is_new {
		return fmt.aprintf(
			"NEW · %s",
			platform.format_date(f64(time.to_unix_seconds(release)) * 1000, "d MMM"),
			allocator = allocator,
		)
	}

	return strings.clone(date[:4], allocator)
}

@(private)
watch_catalog_id :: proc(name, artist, queue_id: string) -> (string, apple.Phase) {
	if matching.is_catalog_id(queue_id) do return queue_id, .Ready

	term := apple.to_query_text(fmt.tprintf("%s %s", name, artist))
	watched := apple.watch(
		fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=10", apple.STOREFRONT, term),
	)
	if watched.phase != .Ready do return "", watched.phase

	answer: apple.Search_Answer
	_ = core.unmarshal_text(watched.body, &answer)
	songs := answer.results.songs.data
	if len(songs) == 0 do return "", .Failed

	for found in songs {
		if found.attributes.name == name && found.attributes.artist_name == artist {
			return strings.clone(found.id, context.temp_allocator), .Ready
		}
	}

	return strings.clone(songs[0].id, context.temp_allocator), .Ready
}

@(private)
apply_song_details :: proc(path: string, data: ^core.Page_Data, body: string) {
	allocator := core.page_allocator(data)
	resources := apple.to_resources(body, allocator)

	if len(resources) == 0 {
		stored_path, _ := delete_key(&song_details, path)
		delete(stored_path)
		return
	}

	song := resources[0]
	attributes := song.attributes
	albums := apple.read_related(song, "albums")
	artists := apple.read_related(song, "artists")
	has_album := len(albums) > 0
	album := albums[0].attributes if has_album else {}
	artist_id := artists[0].id if len(artists) > 0 else ""
	lyrics_kind := Lyrics_Kind.None

	if attributes.has_time_synced_lyrics {
		lyrics_kind = .Word_By_Word
	} else if attributes.has_lyrics {
		lyrics_kind = .Plain
	}

	details := Song_Details {
		song              = apple.to_catalog_song(song),
		album             = attributes.album_name,
		copyright         = album.copyright,
		url               = attributes.url,
		artist_id         = artist_id,
		album_id          = albums[0].id if has_album else "",
		composer          = attributes.composer_name,
		genre             = strings.join(attributes.genre_names, ", ", allocator),
		released          = strings.clone(kit.to_date_text(attributes.release_date), allocator),
		label             = album.record_label,
		isrc              = attributes.isrc,
		language          = to_language_name(attributes.audio_locale),
		lyrics            = lyrics_kind,
		traits            = attributes.audio_traits,
		is_digital_master = attributes.is_apple_digital_master,
		is_explicit       = attributes.content_rating == "explicit",
	}

	if artist_id != "" {
		details.artist_path = fmt.aprintf(
			"/v1/catalog/%s/artists/%s?views=top-songs,latest-release,full-albums,similar-artists",
			apple.STOREFRONT,
			artist_id,
			allocator = allocator,
		)
	}

	if path in song_details {
		song_details[path] = details
	} else {
		song_details[strings.clone(path)] = details
	}
}

@(private = "file")
to_language_name :: proc(locale: string) -> string {
	names := [][2]string {
		{"en", "English"},
		{"ja", "Japanese"},
		{"ko", "Korean"},
		{"zh", "Chinese"},
		{"id", "Indonesian"},
		{"es", "Spanish"},
		{"fr", "French"},
		{"de", "German"},
		{"it", "Italian"},
		{"pt", "Portuguese"},
		// zxx is the ISO 639 code for no language, as for an instrumental. It shows no pill.
		{"zxx", ""},
	}

	language := locale
	if dash := strings.index_byte(locale, '-'); dash > 0 do language = locale[:dash]

	for name in names do if name[0] == language do return name[1]

	return locale
}
