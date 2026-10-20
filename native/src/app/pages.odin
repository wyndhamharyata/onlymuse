package app

import "core:fmt"
import "om:apple"
import "om:ui"

build_page_area :: proc() {
	area := ui.box("page area", {width = ui.fill(), height = ui.fill(), axis = .Y})

	if ui.scope(area) {
		build_page_backdrop()
		toolbar := ui.box("toolbar", {width = ui.fill(), height = ui.points(TOOLBAR_HEIGHT_POINTS), axis = .X, align = .Center, gap = 2, padding = {PAGE_PADDING_POINTS - 4, 0, 0, 0}})

		if ui.scope(toolbar) {
			if icon_button("back", "chevron.left", 16, colors.text, can_go_back()) do go_back()
			if icon_button("forward", "chevron.right", 16, colors.text, can_go_forward()) do go_forward()
		}

		page := current_page()
		// Each page in the history keeps its own scroll, as its boxes are keyed under its place and ID.
		page_box := ui.box(fmt.tprintf("page %d %v %s", navigation.index, page.kind, page.id), {width = ui.fill(), height = ui.fill(), axis = .Y})

		if ui.scope(page_box) do build_page(page)
	}
}

build_page :: proc(page: Page) {
	switch page.kind {
	case .Home:
		build_shelves_page("Home", apple.HOME_PATH, false)
	case .New:
		build_shelves_page("New", apple.NEW_PATH, true)
	case .Favourite_Songs:
		build_favourite_songs_page()
	case .Recently_Added:
		build_recently_added_page()
	case .Artists:
		build_artists_page()
	case .Albums:
		build_albums_page()
	case .Songs:
		build_songs_page()
	case .Downloaded:
		build_downloaded_page()
	case .Playlist, .Catalog_Playlist:
		build_playlist_page(page)
	case .Album:
		build_album_page(page.id)
	case .Artist:
		build_artist_page(page.id, page.title)
	case .Search:
		build_search_page(page.id)
	case .Now_Playing:
		build_now_playing_page()
	}
}
