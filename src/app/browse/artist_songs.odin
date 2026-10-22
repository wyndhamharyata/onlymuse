package browse

import "core:fmt"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:apple"
import "om:ui"

// The number of releases whose songs make up an artist's Recent Songs.
RECENT_RELEASE_COUNT :: 10

// The number of recent songs the artist page shows. The › opens all of them.
SHOWN_RECENT_SONG_COUNT :: 10

// Lists the songs of the artist's ten newest releases, newest first by each song's own date.
// dates[i] is the date of songs[i] as Apple writes it, such as "2026-09-02".
list_recent_songs :: proc(
	artist_id: string,
) -> (
	songs: []core.Catalog_Song,
	dates: []string,
	phase: apple.Phase,
) {
	releases_path := fmt.tprintf(
		"/v1/catalog/%s/artists/%s?views=singles,full-albums",
		apple.STOREFRONT,
		artist_id,
	)
	releases := apple.watch(releases_path)
	release_data, is_stale := core.find_page_data(releases_path, releases.version, releases.phase)
	if is_stale && releases.phase == .Ready do read_newest_release_ids(release_data, releases.body)
	if releases.phase != .Ready do return nil, nil, releases.phase

	// link_id holds the newest releases' IDs, joined by commas.
	if release_data.link_id == "" do return nil, nil, .Ready

	albums_path := fmt.tprintf(
		"/v1/catalog/%s/albums?ids=%s&include=tracks",
		apple.STOREFRONT,
		release_data.link_id,
	)
	albums := apple.watch(albums_path)
	data, is_songs_stale := core.find_page_data(albums_path, albums.version, albums.phase)

	if is_songs_stale && albums.phase == .Ready {
		read_recent_songs(data, albums.body, release_data.link_id)
	}

	return data.songs, data.dates, albums.phase
}

// @(private = "file") hides this procedure from the other files of the package.
@(private = "file")
read_newest_release_ids :: proc(data: ^core.Page_Data, body: string) {
	// context.temp_allocator frees its memory at the start of the next frame.
	resources := apple.to_resources(body, context.temp_allocator)
	if len(resources) == 0 do return

	releases := make([dynamic]apple.Resource, context.temp_allocator)
	append(&releases, ..apple.list_view(resources[0], "singles"))
	append(&releases, ..apple.list_view(resources[0], "full-albums"))

	slice.sort_by(
		releases[:],
		proc(a, b: apple.Resource) -> bool {return(
				a.attributes.release_date >
				b.attributes.release_date \
			)},
	)

	ids := make([dynamic]string, context.temp_allocator)
	for release in releases[:min(len(releases), RECENT_RELEASE_COUNT)] do append(&ids, release.id)
	data.link_id = strings.join(ids[:], ",", core.page_allocator(data))
}

@(private = "file")
read_recent_songs :: proc(data: ^core.Page_Data, body: string, ids: string) {
	allocator := core.page_allocator(data)
	albums := apple.to_resources(body, allocator)

	Dated_Song :: struct {
		song: core.Catalog_Song,
		date: string,
	}
	dated := make([dynamic]Dated_Song, context.temp_allocator)
	seen_names := make(map[string]bool, allocator = context.temp_allocator)

	// The IDs come newest release first, so the newer release keeps a song that two releases share.
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

	data.songs = make([]core.Catalog_Song, len(dated), allocator)
	data.dates = make([]string, len(dated), allocator)

	for entry, index in dated {
		data.songs[index] = entry.song
		data.dates[index] = entry.date
	}
}

// Builds the Recent Songs shelf, below Albums, with the songs in two columns.
// The › of its title opens the page of all recent songs.
build_recent_songs_shelf :: proc(artist_id, artist_name: string) {
	songs, dates, phase := list_recent_songs(artist_id)
	if phase != .Ready || len(songs) == 0 do return

	shelf := ui.box(
		"recent songs",
		{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10},
	)

	if ui.scope(shelf) {
		title := ui.box(
			"title",
			{
				width = ui.fit_children(),
				height = ui.fit_children(),
				axis = .X,
				align = .Center,
				gap = 4,
				flags = {.Clickable},
			},
		)
		dim := 1 - 0.3 * title.hot_fraction

		if ui.scope(title) {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = kit.colors.text * {1, 1, 1, dim},
					font_size = 17,
					font_weight = .Bold,
				},
				"Recent Songs",
			)
			kit.icon_box("", "chevron.right", 13, kit.colors.faint * {1, 1, 1, dim})
		}

		if ui.signal(title).is_clicked {
			core.navigate({kind = .Artist_Recent_Songs, id = artist_id, title = artist_name})
		}

		shown := min(len(songs), SHOWN_RECENT_SONG_COUNT)
		lists.build_song_grid(songs[:shown], dates[:shown], songs)
	}
}

// The › opens this page. It shows every recent song the way the other song lists do.
build_artist_recent_songs_page :: proc(artist_id, artist_name: string) {
	songs, dates, phase := list_recent_songs(artist_id)
	lists.build_song_list_page("Recent Songs", artist_name, songs, phase, dates)
}
