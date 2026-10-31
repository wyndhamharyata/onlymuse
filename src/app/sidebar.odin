package app

import "om:app/core"
import "om:app/kit"
import "om:app/menus"
import "om:ui"

build_sidebar :: proc() {
	sidebar := ui.box(
		"sidebar",
		{
			width = ui.points(kit.SIDEBAR_WIDTH_POINTS),
			height = ui.fill(),
			axis = .Y,
			padding = {8, kit.TOOLBAR_HEIGHT_POINTS, 8, 0},
			background = kit.colors.sidebar,
		},
	)

	if ui.scope(sidebar) {
		build_search_field()

		list := ui.box(
			"list",
			{
				width = ui.fill(),
				height = ui.fill(),
				axis = .Y,
				gap = 1,
				padding = {0, 0, 0, 8},
				flags = {.Scroll, .Clip},
			},
		)

		if ui.scope(list) {
			build_sidebar_group("Apple Music", core.apple_music_items, core.app.accent)
			build_sidebar_group("YouTube Music", core.youtube_items, kit.colors.youtube)
			build_sidebar_group("Library", core.library_items, core.app.accent)

			build_group_title("Playlists")
			playlists, _, _ := core.watch_playlists()
			for playlist in playlists {
				build_sidebar_item(
					playlist.name,
					"music.note.list",
					kit.colors.dim,
					{kind = .Playlist, id = playlist.id, title = playlist.name},
					playlist.can_edit,
				)
			}
		}
	}
}

build_sidebar_group :: proc(title: string, items: []core.Sidebar_Item, symbol_color: [4]f32) {
	build_group_title(title)

	for item in items {
		if !core.app.drives_music_app && item.page.kind == .Downloaded do continue

		build_sidebar_item(item.label, item.symbol, symbol_color, item.page)
	}
}

build_group_title :: proc(title: string) {
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			padding = {10, 14, 10, 4},
			text_color = kit.colors.faint,
			font_size = 11,
			font_weight = .Semibold,
		},
		title,
	)
}

build_sidebar_item :: proc(
	label, symbol: string,
	symbol_color: [4]f32,
	page: core.Page,
	can_take_songs := false,
) {
	is_selected := core.current_page() == page
	background := kit.to_accent_tint(core.app.accent) if is_selected else {}
	row := ui.box(
		label if page.id == "" else page.id,
		{
			width = ui.fill(),
			height = ui.points(30),
			axis = .X,
			align = .Center,
			gap = 9,
			padding = {10, 0, 10, 0},
			corner_radius = 7,
			background = background,
			hover_background = background if is_selected else kit.colors.hover,
			press_background = kit.colors.selected,
			flags = {.Clickable},
		},
	)

	signal := ui.signal(row)
	if signal.is_clicked do core.navigate(page)

	if menus.apply_song_drop(signal.is_hovered, page.id, page.title, can_take_songs) {
		row.style.background = kit.to_accent_tint(core.app.accent)
		row.style.border_width = 1.5
		row.style.border_color = core.app.accent
	}

	if ui.scope(row) {
		kit.icon_box(
			"",
			symbol,
			15,
			core.app.accent if is_selected else symbol_color,
			{width = ui.points(18), height = ui.points(18)},
		)
		kit.text_box(label, kit.colors.text)
	}
}
