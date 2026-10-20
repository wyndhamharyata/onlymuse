package app

import "om:ui"

Sidebar_Item :: struct {
	kind:   Page_Kind,
	label:  string,
	symbol: string,
}

apple_music_items := []Sidebar_Item{{.Home, "Home", "house"}, {.New, "New", "square.grid.2x2"}}

library_items := []Sidebar_Item {
	{.Favourite_Songs, "Favourite Songs", "star"},
	{.Recently_Added, "Recently Added", "clock"},
	{.Artists, "Artists", "music.mic"},
	{.Albums, "Albums", "square.stack"},
	{.Songs, "Songs", "music.note"},
	{.Downloaded, "Downloaded", "arrow.down.circle"},
}

// The traffic lights take the top of the sidebar.
TRAFFIC_LIGHTS_HEIGHT_POINTS :: 44

build_sidebar :: proc() {
	sidebar := ui.box("sidebar", {
		width        = ui.points(SIDEBAR_WIDTH_POINTS),
		height       = ui.fill(),
		axis         = .Y,
		padding      = {8, TRAFFIC_LIGHTS_HEIGHT_POINTS, 8, 0},
		background   = colors.sidebar,
	})

	// The parent is popped where the if ends, so the children stay inside its block.
	if ui.scope(sidebar) {
		build_search_field()

		list := ui.box("list", {width = ui.fill(), height = ui.fill(), axis = .Y, gap = 1, padding = {0, 0, 0, 8}, flags = {.Scroll, .Clip}})

		if ui.scope(list) {
			build_group_title("Apple Music")
			for item in apple_music_items do build_sidebar_item(item.label, item.symbol, app.accent, {kind = item.kind})

			build_group_title("Library")
			for item in library_items do build_sidebar_item(item.label, item.symbol, app.accent, {kind = item.kind})

			build_group_title("Playlists")
			playlists, _, _ := list_playlists()
			for playlist in playlists do build_sidebar_item(playlist.name, "music.note.list", colors.dim, {kind = .Playlist, id = playlist.id, title = playlist.name})
		}

	}
}
