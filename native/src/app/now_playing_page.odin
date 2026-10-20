package app

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "om:apple"
import "om:ui"

MIN_NOW_PLAYING_COVER_POINTS :: 200
MAX_NOW_PLAYING_COVER_POINTS :: 420
// Narrower than this, the details go under the cover.
SIDE_BY_SIDE_POINTS :: 620
DETAIL_LABEL_POINTS :: 110

@(private = "file")
Detail :: struct {
	label, value: string,
}

@(private = "file")
Song_Details :: struct {
	name, artist, album, year, copyright, notes: string,
	artist_id, album_id:                         string,
	artwork:                                     apple.Artwork,
	badges:                                      []string,
	details:                                     []Detail,
}

@(private = "file")
song_details: map[string]Song_Details

@(private = "file")
quality_badges := [][2]string {
	{"hi-res-lossless", "HI-RES LOSSLESS"},
	{"lossless", "LOSSLESS"},
	{"atmos", "DOLBY ATMOS"},
	{"spatial", "SPATIAL AUDIO"},
}

// The song playing, or paused, with its cover large and everything Apple says of it.
build_now_playing_page :: proc() {
	song, is_song := find_shown_song()
	queue_song, is_queue_song := find_queue_song(song.persistent_id)
	page := page_scroll("now playing")

	if ui.scope(page) {
		if !is_song {
			page_heading("Now Playing")
			note("Nothing is playing. Play a song and it shows here.")
			return
		}

		catalog_id, phase := find_catalog_id(song.name, song.artist, queue_song.id if is_queue_song else "")
		path := fmt.tprintf("/v1/catalog/%s/songs/%s?include=albums,artists", apple.STOREFRONT, catalog_id) if catalog_id != "" else ""
		watched := apple.watch(path) if path != "" else apple.Watched{phase = phase}
		data, is_stale := find_page_data(path if path != "" else "now playing", watched.version, watched.phase)
		if is_stale && watched.phase == .Ready do read_song_details(path, data, watched.body)

		details, has_details := song_details[path]
		if !has_details || watched.phase != .Ready {
			// Until Apple answers, what Music.app gave.
			details = {name = song.name, artist = song.artist, album = song.album}
			if is_queue_song do details.artwork = queue_song.artwork
		}

		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width <= 0 do return

		is_side_by_side := width >= SIDE_BY_SIDE_POINTS
		cover_points := clamp(math.floor(width * (0.42 if is_side_by_side else 0.7)), MIN_NOW_PLAYING_COVER_POINTS, MAX_NOW_PLAYING_COVER_POINTS)
		top := ui.box("top", {width = ui.fill(), height = ui.fit_children(), axis = .X if is_side_by_side else .Y, gap = 24})

		if ui.scope(top) {
			source := apple.to_artwork_url(details.artwork, to_artwork_pixels(cover_points))
			if source == "" do source = song.artwork_path
			artwork_box(source, cover_points, 12, to_placeholder(details.artwork, details.album, "music.note"))

			info := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 6})
			if ui.scope(info) do build_song_info_column(details, watched.phase)
		}

		if details.notes != "" {
			about := ui.box("about", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 8})

			if ui.scope(about) {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, "About the Album")
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, flags = {.Wrap_Text}}, details.notes)
			}
		}
	}
}

@(private = "file")
build_song_info_column :: proc(details: Song_Details, phase: apple.Phase) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 30, font_weight = .Bold, flags = {.Wrap_Text}}, details.name)

	artist := ui.box("artist", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent, font_size = 18, font_weight = .Semibold, flags = {.Clickable} if details.artist_id != "" else {}}, details.artist)
	if ui.signal(artist).is_clicked do navigate({kind = .Artist, id = details.artist_id, title = details.artist})

	album_line := details.album if details.year == "" else fmt.tprintf("%s · %s", details.album, details.year)
	album := ui.box("album", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.text if details.album_id != "" else colors.dim, font_size = 15, flags = {.Clickable} if details.album_id != "" else {}}, album_line)
	if ui.signal(album).is_clicked do navigate({kind = .Album, id = details.album_id})

	if len(details.badges) > 0 {
		badges := ui.box("badges", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 6, padding = {0, 6, 0, 2}})
		if ui.scope(badges) do for label in details.badges do build_badge(label, colors.dim)
	}

	if phase != .Ready {
		text_box(phase_note(phase), colors.faint)
		return
	}

	table := ui.box("details", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 6, padding = {0, 10, 0, 4}})

	if ui.scope(table) {
		for detail in details.details {
			row := ui.box(detail.label, {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12})

			if ui.scope(row) {
				ui.box("", {width = ui.points(DETAIL_LABEL_POINTS), height = ui.fit_text(), text_color = colors.faint}, detail.label)
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, flags = {.Wrap_Text}}, detail.value)
			}
		}
	}

	if details.copyright != "" do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11.5, padding = {0, 6, 0, 0}, flags = {.Wrap_Text}}, details.copyright)
}

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

	details := Song_Details {
		name      = attributes.name,
		artist    = attributes.artist_name,
		album     = attributes.album_name,
		year      = attributes.release_date[:min(4, len(attributes.release_date))],
		artwork   = attributes.artwork,
		copyright = album.copyright,
		notes     = to_plain_text(album.editorial_notes.standard, allocator),
		artist_id = artists[0].id if len(artists) > 0 else "",
		album_id  = albums[0].id if len(albums) > 0 else "",
	}

	badges := make([dynamic]string, allocator)
	for badge in quality_badges do if slice.contains(attributes.audio_traits, badge[0]) do append(&badges, badge[1])
	// Hi-res lossless is lossless too, so only the better shows.
	if slice.contains(badges[:], "HI-RES LOSSLESS") do ordered_remove(&badges, 1)
	if attributes.is_apple_digital_master do append(&badges, "APPLE DIGITAL MASTER")
	if attributes.content_rating == "explicit" do append(&badges, "EXPLICIT")
	details.badges = badges[:]

	rows := make([dynamic]Detail, allocator)
	add :: proc(rows: ^[dynamic]Detail, label, value: string) {
		if value != "" do append(rows, Detail{label, value})
	}

	add(&rows, "Composer", attributes.composer_name)
	if attributes.album_artist_name != attributes.artist_name do add(&rows, "Album Artist", attributes.album_artist_name)
	add(&rows, "Genre", strings.join(attributes.genre_names, ", ", allocator))
	add(&rows, "Released", to_date_text(attributes.release_date, allocator))

	if attributes.track_number > 0 {
		track := fmt.aprintf("%d", attributes.track_number, allocator = allocator)
		if album.track_count > 0 do track = fmt.aprintf("%d of %d", attributes.track_number, album.track_count, allocator = allocator)
		if attributes.disc_number > 1 do track = fmt.aprintf("%s, disc %d", track, attributes.disc_number, allocator = allocator)
		add(&rows, "Track", track)
	}

	add(&rows, "Length", strings.clone(to_clock_text(attributes.duration_ms / 1000), allocator))
	add(&rows, "Language", to_language_name(attributes.audio_locale))

	lyrics := "Word by word" if attributes.has_time_synced_lyrics else "Yes" if attributes.has_lyrics else "None"
	add(&rows, "Lyrics", lyrics)
	add(&rows, "Record Label", album.record_label)
	add(&rows, "ISRC", attributes.isrc)
	details.details = rows[:]

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

// Apple's notes are HTML. The tags go, and a break becomes a space.
@(private = "file")
to_plain_text :: proc(html: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	is_in_tag := false

	for character in html {
		switch {
		case character == '<':
			is_in_tag = true
		case character == '>':
			is_in_tag = false
			strings.write_byte(&builder, ' ')
		case !is_in_tag:
			strings.write_rune(&builder, character)
		}
	}

	collapsed, _ := strings.replace_all(strings.trim_space(strings.to_string(builder)), "  ", " ", allocator)

	return collapsed
}
