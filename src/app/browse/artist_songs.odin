package browse

import "core:fmt"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:apple"
import "om:ui"

RECENT_RELEASE_COUNT :: 10

SHOWN_RECENT_SONG_COUNT :: 10

@(private = "file")
HOVER_FADE :: 0.3

watch_recent_songs :: proc(
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
	release_data, needs_read := core.find_page_data(
		releases_path,
		releases.version,
		releases.phase,
	)
	if releases.phase != .Ready do return nil, nil, releases.phase
	if needs_read do read_newest_release_ids(release_data, releases.body)

	if release_data.release_ids == "" do return nil, nil, .Ready

	albums_path := fmt.tprintf(
		"/v1/catalog/%s/albums?ids=%s&include=tracks",
		apple.STOREFRONT,
		release_data.release_ids,
	)
	albums := apple.watch(albums_path)
	data, needs_songs_read := core.find_page_data(albums_path, albums.version, albums.phase)

	if needs_songs_read do read_recent_songs(data, albums.body, release_data.release_ids)

	return data.songs, data.dates, albums.phase
}

@(private = "file")
read_newest_release_ids :: proc(data: ^core.Page_Data, body: string) {
	resources := apple.to_resources(body, context.temp_allocator)
	if len(resources) == 0 do return

	releases := make([dynamic]apple.Resource, context.temp_allocator)
	append(&releases, ..apple.read_view(resources[0], "singles"))
	append(&releases, ..apple.read_view(resources[0], "full-albums"))

	slice.sort_by(
		releases[:],
		proc(a, b: apple.Resource) -> bool {return(
				a.attributes.release_date >
				b.attributes.release_date \
			)},
	)

	ids := make([dynamic]string, context.temp_allocator)
	for release in releases[:min(len(releases), RECENT_RELEASE_COUNT)] do append(&ids, release.id)
	data.release_ids = strings.join(ids[:], ",", core.page_allocator(data))
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

	for id in strings.split(ids, ",", context.temp_allocator) {
		for album in albums {
			if album.id != id do continue

			for track in apple.read_related(album, "tracks") {
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

build_recent_songs_shelf :: proc(artist_id, artist_name: string) {
	songs, dates, phase := watch_recent_songs(artist_id)
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
		text_alpha := 1 - HOVER_FADE * title.hot_fraction

		if ui.scope(title) {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = kit.to_faded(kit.colors.text, text_alpha),
					font_size = kit.SHELF_TITLE_POINTS,
					font_weight = .Bold,
				},
				"Recent Songs",
			)
			kit.icon_box("", "chevron.right", 13, kit.to_faded(kit.colors.faint, text_alpha))
		}

		if ui.signal(title).is_clicked {
			core.navigate({kind = .Artist_Recent_Songs, id = artist_id, title = artist_name})
		}

		shown := min(len(songs), SHOWN_RECENT_SONG_COUNT)
		lists.build_song_grid(songs[:shown], dates[:shown], songs)
	}
}

build_artist_recent_songs_page :: proc(artist_id, artist_name: string) {
	songs, dates, phase := watch_recent_songs(artist_id)
	lists.build_song_list_page("Recent Songs", artist_name, songs, phase, dates)
}
