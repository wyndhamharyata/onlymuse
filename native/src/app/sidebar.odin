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
		padding      = {10, TRAFFIC_LIGHTS_HEIGHT_POINTS, 10, 0},
		background   = colors.sidebar,
	})

	// The parent is popped where the if ends, so the children stay inside its block.
	if ui.scope(sidebar) {
		build_search_field()

		list := ui.box("list", {width = ui.fill(), height = ui.fill(), axis = .Y, gap = 1, padding = {0, 0, 0, 12}, flags = {.Scroll, .Clip}})

		if ui.scope(list) {
			build_group_title("Apple Music")
			for item in apple_music_items do build_sidebar_item(item.label, item.symbol, app.accent, {kind = item.kind})

			build_group_title("Library")
			for item in library_items do build_sidebar_item(item.label, item.symbol, app.accent, {kind = item.kind})

			build_group_title("Playlists")
			playlists, _, _ := list_playlists()
			for playlist in playlists do build_sidebar_item(playlist.name, "music.note.list", colors.dim, {kind = .Playlist, id = playlist.id, title = playlist.name})
		}

		build_panel_tabs()
	}
}

// The one control for the side panel. A click on the open tab closes the panel.
build_panel_tabs :: proc() {
	tabs := ui.box("panel tabs", {
		width         = ui.fill(),
		height        = ui.points(32),
		axis          = .X,
		gap           = 2,
		padding       = {2, 2, 2, 2},
		corner_radius = 9,
		background    = colors.field,
	})

	if ui.scope(tabs) {
		build_panel_tab("Up Next", "list.bullet", .Up_Next)
		build_panel_tab("Lyrics", "quote.bubble", .Lyrics)
	}

	ui.box("", {width = ui.fill(), height = ui.points(10)})
}

@(private = "file")
build_panel_tab :: proc(label, symbol: string, panel: Panel) {
	is_open := app.panel == panel
	tint := to_accent_tint(app.accent)
	tab := ui.box(label, {
		width            = ui.fill(),
		height           = ui.fill(),
		axis             = .X,
		align            = .Center,
		gap              = 6,
		padding          = {10, 0, 10, 0},
		corner_radius    = 7,
		background       = tint if is_open else {},
		hover_background = tint if is_open else colors.hover,
		press_background = colors.selected,
		flags            = {.Clickable},
	})

	if ui.signal(tab).is_clicked do toggle_panel(panel)

	if ui.scope(tab) {
		spacer()
		color := app.accent if is_open else colors.dim
		icon_box("", symbol, 13, color)
		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent if is_open else colors.text, font_size = 12.5, font_weight = .Semibold}, label)
		spacer()
	}
}

build_group_title :: proc(title: string) {
	ui.box("", {width = ui.fill(), height = ui.fit_text(), padding = {10, 14, 10, 4}, text_color = colors.faint, font_size = 11, font_weight = .Semibold}, title)
}

build_sidebar_item :: proc(label, symbol: string, symbol_color: [4]f32, page: Page) {
	is_selected := current_page() == page
	// The selected row takes the accent, as the playing song does.
	background := to_accent_tint(app.accent) if is_selected else {}
	row := ui.box(label if page.id == "" else page.id, {
		width            = ui.fill(),
		height           = ui.points(30),
		axis             = .X,
		align            = .Center,
		gap              = 9,
		padding          = {10, 0, 10, 0},
		corner_radius    = 7,
		background       = background,
		hover_background = background if is_selected else colors.hover,
		press_background = colors.selected,
		flags            = {.Clickable},
	})

	if ui.signal(row).is_clicked do navigate(page)

	if ui.scope(row) {
		icon_box("", symbol, 15, app.accent if is_selected else symbol_color, {width = ui.points(18), height = ui.points(18)})
		text_box(label, colors.text)
	}
}

