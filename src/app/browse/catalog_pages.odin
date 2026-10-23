package browse

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/youtube_lists"
import "om:apple"
import "om:ui"

build_shelves_page :: proc(title, path: string, is_new: bool) {
	watched := apple.watch(path)
	youtube_shelves: []apple.Shelf
	youtube_version := 0
	if !is_new do youtube_shelves, youtube_version, _ = youtube_lists.watch_youtube_home()
	data, needs_read := core.find_page_data(
		path,
		core.mix_version(watched.version, youtube_version),
		watched.phase,
	)

	if needs_read {
		allocator := core.page_allocator(data)
		apple_shelves :=
			apple.to_new_shelves(watched.body, allocator) if is_new else apple.to_home_shelves(watched.body, allocator)
		data.shelves = youtube_lists.merge_youtube_shelves(
			apple_shelves,
			youtube_shelves,
			allocator,
		)
	}

	page := kit.page_scroll("shelves")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		kit.page_heading(title)

		if watched.phase != .Ready {
			kit.build_phase(watched.phase, title)
			return
		}

		width := kit.to_content_width(page)
		if width <= 0 do return

		for shelf, index in data.shelves {
			target_points: f32 =
				lists.FIRST_SHELF_TILE_POINTS if index == 0 else lists.SHELF_TILE_POINTS
			lists.build_shelf(fmt.tprintf("shelf %d", index), shelf, width, target_points)
		}
	}
}

build_playlist_page :: proc(page: core.Page) {
	is_catalog := page.kind == .Catalog_Playlist
	header_path :=
		fmt.tprintf("/v1/catalog/%s/playlists/%s", apple.STOREFRONT, page.id) if is_catalog else ""
	tracks_path :=
		fmt.tprintf("/v1/catalog/%s/playlists/%s/tracks", apple.STOREFRONT, page.id) if is_catalog else fmt.tprintf("/v1/me/library/playlists/%s/tracks", page.id)
	bodies, signature, phase := core.watch_all_pages(tracks_path)
	header := apple.watch(header_path) if is_catalog else {phase = .Ready}
	data, needs_read := core.find_page_data(
		tracks_path,
		core.mix_version(
			core.mix_version(signature, header.version),
			youtube_lists.playlist_youtube_version,
		),
		phase,
	)

	if needs_read {
		core.read_library_songs(data, bodies)

		if !is_catalog {
			data.songs = youtube_lists.merge_playlist_youtube_songs(
				page.id,
				data.songs,
				core.page_allocator(data),
			)
		}

		resources :=
			apple.to_resources(header.body, core.page_allocator(data)) if is_catalog && header.phase == .Ready else nil

		if len(resources) > 0 {
			data.title = resources[0].attributes.name
			data.subtitle = resources[0].attributes.curator_name
		}
	}

	title := data.title if data.title != "" else page.title
	lists.build_song_list_page(title, data.subtitle, data.songs, phase)
}

build_favourite_songs_page :: proc() {
	_, playlist_id, phase := core.watch_playlists()

	if playlist_id == "" {
		lists.build_song_list_page("Favourite Songs", "", nil, phase)
		return
	}

	build_playlist_page({kind = .Playlist, id = playlist_id, title = "Favourite Songs"})
}
