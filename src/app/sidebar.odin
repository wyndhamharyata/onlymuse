package main

import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "thor:kit"
import "thor:ui"

build_sidebar :: proc() {
	sidebar := ui.box(
		"sidebar",
		{
			width = ui.points(look.SIDEBAR_WIDTH_POINTS),
			height = ui.fill(),
			axis = .Y,
			padding = {8, look.TOOLBAR_HEIGHT_POINTS, 8, 0},
			background = look.colors.sidebar,
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
			build_sidebar_group("Apple Music", core.apple_music_items, kit.colors.primary)
			build_sidebar_group("YouTube Music", core.youtube_items, look.colors.youtube)
			build_sidebar_group("Library", core.library_items, kit.colors.primary)

			build_group_title("Playlists")
			playlists, _, _ := core.watch_playlists()
			for playlist in playlists {
				build_sidebar_item(
					playlist.name,
					"music.note.list",
					kit.to_faded(kit.colors.base_content, 0.7),
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
			text_color = kit.to_faded(kit.colors.base_content, 0.5),
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
	background := kit.to_faded(kit.colors.primary, kit.SOFT_OPACITY) if is_selected else {}
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
			hover_background = background if is_selected else kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY),
			press_background = kit.to_faded(kit.colors.base_content, kit.SELECTED_OPACITY),
			flags = {.Clickable},
		},
	)

	signal := ui.signal(row)
	if signal.is_clicked do core.navigate(page)

	if menus.apply_song_drop(signal.is_hovered, page.id, page.title, can_take_songs) {
		row.style.background = kit.to_faded(kit.colors.primary, kit.SOFT_OPACITY)
		row.style.border_width = 1.5
		row.style.border_color = kit.colors.primary
	}

	if ui.scope(row) {
		kit.icon_box(
			"",
			symbol,
			15,
			kit.colors.primary if is_selected else symbol_color,
			{width = ui.points(18), height = ui.points(18)},
		)
		kit.text(label, kit.colors.base_content)
	}
}
