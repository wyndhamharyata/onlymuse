package browse

import "om:app/core"
import "om:app/lists"
import "om:apple"

build_songs_page :: proc() {
	songs, _, phase := core.list_library_songs()
	lists.build_song_list_page("Songs", "", songs, phase)
}

build_albums_page :: proc() {
	cards, _, phase := core.list_library_albums()
	lists.build_card_grid_page("Albums", cards, phase, false)
}

build_artists_page :: proc() {
	cards, _, phase := core.list_library_artists()
	lists.build_card_grid_page("Artists", cards, phase, true)
}

build_recently_added_page :: proc() {
	path := "/v1/me/library/recently-added?limit=25"
	watched := apple.watch(path)
	data, is_stale := core.find_page_data(path, watched.version, watched.phase)
	if is_stale && watched.phase == .Ready do core.read_cards(data, {watched.body})

	lists.build_card_grid_page("Recently Added", data.cards, watched.phase, false)
}
