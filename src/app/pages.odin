package main

import "core:fmt"
import "om:app/browse"
import "om:app/core"
import "om:app/look"
import "om:app/player"
import "om:app/youtube_pages"
import "om:apple"
import "thor:kit"
import "thor:ui"

build_page_area :: proc() {
	area := ui.box("page_area", {width = ui.fill(), height = ui.fill(), axis = .Y})

	if ui.scope(area) {
		player.build_page_backdrop()

		toolbar := ui.box(
			"toolbar",
			{
				width = ui.fill(),
				height = ui.points(look.TOOLBAR_HEIGHT_POINTS),
				axis = .X,
				align = .Center,
				gap = 2,
				padding = {look.PAGE_PADDING_POINTS - kit.ICON_BUTTON_PADDING_POINTS, 0, 0, 0},
			},
		)

		if ui.scope(toolbar) {
			if kit.button("back", icon = "chevron.left", icon_size = 16, is_disabled = !core.can_go_back(), tooltip = "Back").is_activated {
				core.go_back()
			}

			if kit.button("forward", icon = "chevron.right", icon_size = 16,
				is_disabled = !core.can_go_forward(), tooltip = "Forward",
			).is_activated {
				core.go_forward()
			}
		}

		page := core.current_page()
		page_box := ui.box(
			fmt.tprintf("page_%d_%v_%s", core.navigation.index, page.kind, page.id),
			{width = ui.fill(), height = ui.fill(), axis = .Y},
		)

		if ui.scope(page_box) do build_page(page)
	}
}

build_page :: proc(page: core.Page) {
	switch page.kind {
	case .Home:
		browse.build_shelves_page("Home", apple.HOME_PATH, false)
	case .New:
		browse.build_shelves_page("New", apple.NEW_PATH, true)
	case .Favourite_Songs:
		browse.build_favourite_songs_page()
	case .Recently_Added:
		browse.build_recently_added_page()
	case .Artists:
		browse.build_artists_page()
	case .Albums:
		browse.build_albums_page()
	case .Songs:
		browse.build_songs_page()
	case .Downloaded:
		browse.build_downloaded_page()
	case .Playlist, .Catalog_Playlist:
		browse.build_playlist_page(page)
	case .Album:
		browse.build_album_page(page.id)
	case .Artist:
		browse.build_artist_page(page.id, page.title)
	case .Artist_Recent_Songs:
		browse.build_artist_recent_songs_page(page.id, page.title)
	case .Search:
		browse.build_search_page(page.id)
	case .Now_Playing:
		player.build_now_playing_page()
	case .YouTube_Playlist:
		youtube_pages.build_youtube_playlist_page(page)
	case .YouTube_Mixes:
		youtube_pages.build_youtube_mixes_page()
	case .Bring_Over:
		youtube_pages.build_bring_over_page(page)
	case .Console:
		build_console_page()
	}
}
