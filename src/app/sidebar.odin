package main

import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "thor:kit"
import "thor:ui"

build_sidebar :: proc() {
	sidebar := ui.col(
		"sidebar",
		{
			width = ui.points(look.SIDEBAR_WIDTH),
			height = ui.fill(),
			padding = {8, look.toolbar_height(), 8, 0},
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
				flags = {.Scroll, .Clip, .Arrow_Keys},
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
	page_id := page.id
	if page_id == "" do page_id = core.page_kind_id(page.kind)
	// The row compares this with its id, so it reads as current only on the current page.
	current := page_id if core.current_page() == page else ""
	is_current := current != ""
	icon_color := kit.colors.primary if is_current else symbol_color

	if kit.nav_row(page_id, &current, label, symbol, .Primary, icon_color) {
		row := ui.here()
		if row.is_activated do core.navigate(page)

		if menus.apply_song_drop(row.is_hovered, page.id, page.title, can_take_songs) {
			row.box.style.bg = kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
			row.box.style.border_width = 1.5
			row.box.style.border_color = kit.colors.primary
		}
	}
}
