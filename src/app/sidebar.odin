package main

import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "thor:kit"
import "thor:ui"

build_sidebar :: proc() {
	sidebar := kit.safe_area(
		"sidebar",
		{
			width = ui.points(look.SIDEBAR_WIDTH),
			height = ui.fill(),
			padding = {8, look.TOOLBAR_HEIGHT - look.TITLE_BAR_HEIGHT, 8, 0},
			bg = look.colors.sidebar,
		},
	)

	if sidebar {
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
					kit.with_opacity(kit.colors.base_content, 0.7),
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
			padding = {10, 14, 10, 4},
			text_color = kit.with_opacity(kit.colors.base_content, 0.5),
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
	bg := kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY) if is_selected else {}
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
			bg = bg,
			hover_bg = bg if is_selected else kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY),
			press_bg = kit.with_opacity(kit.colors.base_content, kit.SELECTED_OPACITY),
			pointer = .Click,
		},
	)

	signal := ui.signal(row)
	if signal.is_activated do core.navigate(page)

	if menus.apply_song_drop(signal.is_hovered, page.id, page.title, can_take_songs) {
		row.style.bg = kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
		row.style.border_width = 1.5
		row.style.border_color = kit.colors.primary
	}

	if ui.scope(row) {
		kit.icon_box(
			symbol,
			15,
			kit.colors.primary if is_selected else symbol_color,
			{width = ui.points(18), height = ui.points(18)},
		)
		kit.text(label, kit.colors.base_content)
	}
}
