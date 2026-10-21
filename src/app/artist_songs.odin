package app

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "om:apple"
import "om:ui"

// The releases whose songs make an artist's Recent Songs.
RECENT_RELEASE_COUNT :: 10
// The songs the artist page shows. The › opens all of them.
RECENT_SONGS_SHOWN :: 10
// A grid column narrower than these leaves a song's name no room: the grid takes one column, and a row
// leaves out its date.
MIN_GRID_COLUMN_POINTS :: 300
MIN_DATED_COLUMN_POINTS :: 420
GRID_GAP_POINTS :: 20

// The songs of the artist's ten newest releases, newest first by each song's own date, which is not
// always its album's. A song on a single and on a later album appears once, from the newer release.
// dates[i] is songs[i]'s, as Apple writes it, such as "2026-09-02".
list_recent_songs :: proc(artist_id: string) -> (songs: []Catalog_Song, dates: []string, phase: apple.Phase) {
	releases_path := fmt.tprintf("/v1/catalog/%s/artists/%s?views=singles,full-albums", apple.STOREFRONT, artist_id)
	releases := apple.watch(releases_path)
	release_data, is_stale := find_page_data(releases_path, releases.version, releases.phase)
	if is_stale && releases.phase == .Ready do read_newest_release_ids(release_data, releases.body)
	if releases.phase != .Ready do return nil, nil, releases.phase

	// link_id holds the newest releases' IDs, joined by commas.
	if release_data.link_id == "" do return nil, nil, .Ready

	albums_path := fmt.tprintf("/v1/catalog/%s/albums?ids=%s&include=tracks", apple.STOREFRONT, release_data.link_id)
	albums := apple.watch(albums_path)
	data, is_songs_stale := find_page_data(albums_path, albums.version, albums.phase)
	if is_songs_stale && albums.phase == .Ready do read_recent_songs(data, albums.body, release_data.link_id)

	return data.songs, data.dates, albums.phase
}

@(private = "file")
read_newest_release_ids :: proc(data: ^Page_Data, body: string) {
	resources := apple.to_resources(body, context.temp_allocator)
	if len(resources) == 0 do return

	releases := make([dynamic]apple.Resource, context.temp_allocator)
	append(&releases, ..apple.list_view(resources[0], "singles"))
	append(&releases, ..apple.list_view(resources[0], "full-albums"))
	slice.sort_by(releases[:], proc(a, b: apple.Resource) -> bool {return a.attributes.release_date > b.attributes.release_date})

	ids := make([dynamic]string, context.temp_allocator)
	for release in releases[:min(len(releases), RECENT_RELEASE_COUNT)] do append(&ids, release.id)
	data.link_id = strings.join(ids[:], ",", page_allocator(data))
}

@(private = "file")
read_recent_songs :: proc(data: ^Page_Data, body: string, ids: string) {
	allocator := page_allocator(data)
	albums := apple.to_resources(body, allocator)

	Dated_Song :: struct {
		song: Catalog_Song,
		date: string,
	}
	dated := make([dynamic]Dated_Song, context.temp_allocator)
	seen_names := make(map[string]bool, allocator = context.temp_allocator)

	// Newest release first, so the newer release keeps a song the two share.
	for id in strings.split(ids, ",", context.temp_allocator) {
		for album in albums {
			if album.id != id do continue

			for track in apple.list_related(album, "tracks") {
				date := track.attributes.release_date
				if date == "" || seen_names[track.attributes.name] do continue

				seen_names[track.attributes.name] = true
				append(&dated, Dated_Song{apple.to_catalog_song(track), date})
			}
		}
	}

	slice.stable_sort_by(dated[:], proc(a, b: Dated_Song) -> bool {return a.date > b.date})

	data.songs = make([]Catalog_Song, len(dated), allocator)
	data.dates = make([]string, len(dated), allocator)
	for entry, index in dated {
		data.songs[index] = entry.song
		data.dates[index] = entry.date
	}
}

// Under Albums on the artist page: the newest songs in two columns, and a title whose › opens them all.
build_recent_songs_shelf :: proc(artist_id, artist_name: string) {
	songs, dates, phase := list_recent_songs(artist_id)
	if phase != .Ready || len(songs) == 0 do return

	shelf := ui.box("recent songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10})

	if ui.scope(shelf) {
		title := ui.box("title", {width = ui.fit_children(), height = ui.fit_children(), axis = .X, align = .Center, gap = 4, flags = {.Clickable}})
		dim := 1 - 0.3 * title.hot_t

		if ui.scope(title) {
			ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.text * {1, 1, 1, dim}, font_size = 17, font_weight = .Bold}, "Recent Songs")
			icon_box("", "chevron.right", 13, colors.faint * {1, 1, 1, dim})
		}

		if ui.signal(title).is_clicked do navigate({kind = .Artist_Recent_Songs, id = artist_id, title = artist_name})

		shown := min(len(songs), RECENT_SONGS_SHOWN)
		build_song_grid(songs[:shown], dates[:shown], songs)
	}
}

// The › page: every recent song, as the other song lists show theirs.
build_artist_recent_songs_page :: proc(artist_id, artist_name: string) {
	songs, dates, phase := list_recent_songs(artist_id)
	build_song_list_page("Recent Songs", artist_name, songs, phase, dates)
}

// Two columns, filled row by row, or one when the page is narrow. A click plays all of playing from
// that song. With dates, each row shows its date, when there is room for it.
build_song_grid :: proc(songs: []Catalog_Song, dates: []string, playing: []Catalog_Song) {
	grid := ui.box("grid", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = GRID_GAP_POINTS})
	current, is_playing := find_queue_song(app.now_playing.song.persistent_id)
	// The grid's width from the last frame, 0 on the first.
	width := grid.size.x
	column_count := 1 if width > 0 && (width - GRID_GAP_POINTS) / 2 < MIN_GRID_COLUMN_POINTS else 2
	column_width := (width - GRID_GAP_POINTS * f32(column_count - 1)) / f32(column_count)
	has_dates := width <= 0 || column_width >= MIN_DATED_COLUMN_POINTS

	if ui.scope(grid) {
		for column in 0 ..< column_count {
			column_box := ui.box(fmt.tprintf("column %d", column), {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(column_box) {
				for index := column; index < len(songs); index += column_count {
					song := songs[index]
					date := to_date_text(dates[index]) if has_dates && index < len(dates) else ""
					if build_song_row(fmt.tprintf("%d %s", index, song.id), song, song.album_name, is_playing && is_same_queue_song(current, song), date) do play_songs(playing, index)
				}
			}
		}
	}
}

// Apple's "2026-09-02" as "2 Sep 2026". "2026-09" and "2026" come out as "Sep 2026" and "2026".
to_date_text :: proc(date: string) -> string {
	MONTHS :: [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	parts := strings.split(date, "-", context.temp_allocator)
	if len(parts) < 2 do return date

	month, ok := strconv.parse_int(parts[1])
	if !ok || month < 1 || month > 12 do return date

	months := MONTHS
	if len(parts) < 3 do return fmt.tprintf("%s %s", months[month - 1], parts[0])

	day := strconv.parse_int(parts[2]) or_else 0

	return fmt.tprintf("%d %s %s", day, months[month - 1], parts[0])
}
