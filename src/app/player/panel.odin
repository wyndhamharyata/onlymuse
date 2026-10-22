package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "om:ui"

// Returns true while the lyrics move.
build_panel :: proc() -> bool {
	is_open := core.app.panel != .None
	width := ui.animate("panel width", kit.PANEL_WIDTH_POINTS if is_open else 0)

	if width < 1 do return false

	panel := ui.box(
		"panel",
		{
			width = ui.points(width),
			height = ui.fill(),
			axis = .Y,
			padding = {8, 8, 8, 8},
			gap = 4,
			background = kit.colors.panel,
			fade = 1 - width / kit.PANEL_WIDTH_POINTS,
			flags = {.Clip},
		},
	)
	is_moving := false
	inner_width: f32 = kit.PANEL_WIDTH_POINTS - 16

	if ui.scope(panel) {
		inner := ui.box(
			"inner",
			{width = ui.points(inner_width), height = ui.fill(), axis = .Y, gap = 4},
		)

		if ui.scope(inner) {
			#partial switch core.app.panel {
			case .Lyrics:
				is_moving = build_lyrics()
			case .Up_Next:
				build_up_next()
			}
		}

		ui.box("", {width = ui.points(1), height = ui.points(4)})
		build_panel_tabs(inner_width)
	}

	return is_moving
}

build_up_next :: proc() {
	if len(playback.queue.songs) == 0 || playback.queue.index < 0 {
		build_panel_note("Play a song or an album, and the songs after it show here.")
		return
	}

	if playback.queue.is_shuffled {
		note_row := ui.box(
			"shuffle note",
			{
				width = ui.fill(),
				height = ui.fit_children(),
				axis = .X,
				align = .Center,
				gap = 8,
				padding = {6, 2, 2, 6},
			},
		)

		if ui.scope(note_row) {
			kit.icon_box("", "shuffle", 11, core.app.accent)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.dim,
					font_size = 11.5,
					flags = {.Wrap_Text},
				},
				playback.shuffle_note if playback.shuffle_note != "" else "Shuffled.",
			)

			rules := ui.box(
				"rules",
				{
					width = ui.fit_text(),
					height = ui.points(22),
					padding = {8, 0, 8, 0},
					corner_radius = 6,
					background = kit.colors.field,
					hover_background = kit.colors.hover,
					text_color = kit.colors.text,
					font_size = 11.5,
					font_weight = .Semibold,
					flags = {.Clickable},
				},
				"Rules",
			)

			if ui.signal(rules).is_clicked {
				playback.open_shuffle_rules({rules.rect.x - 240, rules.rect.w + 4})
			}
		}
	}

	list := ui.box(
		"up next",
		{width = ui.fill(), height = ui.fill(), axis = .Y, gap = 2, flags = {.Scroll, .Clip}},
	)
	row_points: f32 = 52
	first_row := max(
		playback.queue.index,
		playback.queue.index + int(list.scroll / row_points) - lists.EXTRA_ROW_COUNT,
	)
	last_row := min(
		len(playback.queue.songs) - 1,
		playback.queue.index +
		int((list.scroll + list.size.y) / row_points) +
		lists.EXTRA_ROW_COUNT,
	)

	if ui.scope(list) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.points(f32(first_row - playback.queue.index) * row_points),
			},
		)

		for index in first_row ..= last_row do build_queue_row(index, row_points)

		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.points(f32(len(playback.queue.songs) - 1 - last_row) * row_points),
			},
		)
	}
}

build_queue_row :: proc(index: int, row_points: f32) {
	song := playback.queue.songs[index]
	is_current := index == playback.queue.index
	tint := kit.to_accent_tint(core.app.accent)
	row := ui.box(
		fmt.tprintf("queue %d %s", index, song.id),
		{
			width = ui.fill(),
			height = ui.points(row_points - 2),
			axis = .X,
			align = .Center,
			gap = 10,
			padding = {6, 0, 4, 0},
			corner_radius = 6,
			background = tint if is_current else {},
			hover_background = tint if is_current else kit.colors.hover,
			flags = {.Clickable},
		},
	)
	is_removed := false

	if ui.scope(row) {
		kit.artwork_box(
			apple.to_artwork_url(song.artwork, kit.to_artwork_pixels(36)),
			36,
			4,
			kit.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("text", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			is_hovered := ui.signal(row).is_hovered

			kit.scrolling_text(
				"name",
				song.name,
				core.app.accent if is_current else kit.colors.text,
				13,
				.Medium,
				is_hovered = is_hovered,
			)
			kit.scrolling_text(
				"artist",
				song.artist_name,
				kit.colors.dim,
				12,
				is_hovered = is_hovered,
			)
		}

		// The song playing stays. Any other song shows its remove button while the mouse is over it.
		if !is_current && kit.is_mouse_in(row) {
			is_removed = kit.icon_button("remove", "xmark", 11, kit.colors.dim)
		}
	}

	if is_removed {
		playback.remove_from_queue(index)
	} else if menus.apply_song_row_signal(ui.signal(row), song) {
		playback.play_queue_at(index)
	}
}

// Picks what the side panel shows. The button by the volume shows and hides it.
build_panel_tabs :: proc(width: f32) {
	tabs := ui.box(
		"panel tabs",
		{
			width = ui.points(width),
			height = ui.points(30),
			axis = .X,
			gap = 2,
			padding = {2, 2, 2, 2},
			corner_radius = 9,
			background = kit.colors.field,
		},
	)

	if ui.scope(tabs) {
		build_panel_tab("Up Next", "list.bullet", .Up_Next)
		build_panel_tab("Lyrics", "quote.bubble", .Lyrics)
	}
}

@(private = "file")
build_panel_tab :: proc(label, symbol: string, panel: core.Panel) {
	is_open := core.app.panel == panel
	tint := kit.to_accent_tint(core.app.accent)
	tab := ui.box(
		label,
		{
			width = ui.fill(),
			height = ui.fill(),
			axis = .X,
			align = .Center,
			gap = 6,
			padding = {10, 0, 10, 0},
			corner_radius = 7,
			background = tint if is_open else {},
			hover_background = tint if is_open else kit.colors.hover,
			press_background = kit.colors.selected,
			flags = {.Clickable},
		},
	)

	if ui.signal(tab).is_clicked do core.set_panel(panel)

	if ui.scope(tab) {
		kit.spacer()
		color := core.app.accent if is_open else kit.colors.dim
		kit.icon_box("", symbol, 13, color)
		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = core.app.accent if is_open else kit.colors.text,
				font_size = 12.5,
				font_weight = .Semibold,
			},
			label,
		)
		kit.spacer()
	}
}
