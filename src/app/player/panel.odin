package player

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

PANEL_PADDING_POINTS :: 8

QUEUE_ROW_POINTS :: 52

QUEUE_COVER_POINTS :: 36

RULES_MENU_LEFT_POINTS :: 240

build_panel :: proc() -> bool {
	is_open := core.app.panel != .None
	width := ui.animate("panel width", look.PANEL_WIDTH_POINTS if is_open else 0)

	if width < 1 do return false

	panel := ui.box(
		"panel",
		{
			width = ui.points(width),
			height = ui.fill(),
			axis = .Y,
			padding = {
				PANEL_PADDING_POINTS,
				PANEL_PADDING_POINTS,
				PANEL_PADDING_POINTS,
				PANEL_PADDING_POINTS,
			},
			gap = 4,
			background = look.colors.panel,
			fade = 1 - width / look.PANEL_WIDTH_POINTS,
			flags = {.Clip},
		},
	)
	is_moving := false
	inner_width: f32 = look.PANEL_WIDTH_POINTS - 2 * PANEL_PADDING_POINTS

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
	is_queue_empty := len(playback.queue.songs) == 0 || playback.queue.index < 0

	if is_queue_empty {
		build_panel_note("Play a song or an album. The songs after it show here.")
		return
	}

	if playback.queue.is_shuffled {
		note_text := playback.shuffle_note if playback.shuffle_note != "" else "Shuffled."
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
			kit.icon_box("", "shuffle", 11, kit.colors.primary)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.to_faded(kit.colors.base_content, 0.7),
					font_size = 11.5,
					flags = {.Wrap_Text},
				},
				note_text,
			)

			rules := ui.box(
				"rules",
				{
					width = ui.fit_text(),
					height = ui.points(22),
					padding = {8, 0, 8, 0},
					corner_radius = 6,
					background = kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY),
					hover_background = kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY),
					text_color = kit.colors.base_content,
					font_size = 11.5,
					font_weight = .Semibold,
					flags = {.Clickable},
				},
				"Rules",
			)

			if ui.signal(rules).is_clicked {
				playback.open_shuffle_rules(
					{rules.rect.x - RULES_MENU_LEFT_POINTS, rules.rect.w + 4},
				)
			}
		}
	}

	removed_row := -1
	defer if removed_row >= 0 do playback.remove_from_queue(removed_row)

	shown_count := len(playback.queue.songs) - playback.queue.index
	style := ui.Style {
		width   = ui.fill(),
		height  = ui.fill(),
		gap     = 2,
		// The old empty spacer above the rows took a gap, so the rows sat 2 points down.
		padding = {0, 2, 0, 0},
		flags   = {.Scroll, .Clip},
	}

	if first, last, ok := kit.list("up next", shown_count, QUEUE_ROW_POINTS - 2, style); ok {
		for offset in first ..< last {
			index := playback.queue.index + offset
			if build_queue_row(index) do removed_row = index
		}
	}
}

build_queue_row :: proc(index: int) -> bool {
	song := playback.queue.songs[index]
	is_current := index == playback.queue.index
	tint := kit.to_faded(kit.colors.primary, kit.SOFT_OPACITY)
	background: [4]f32 = tint if is_current else {}
	hover_background := tint if is_current else kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY)
	name_color := kit.colors.primary if is_current else kit.colors.base_content
	row := ui.box(
		fmt.tprintf("queue %d %s", index, song.id),
		{
			width = ui.fill(),
			height = ui.points(QUEUE_ROW_POINTS - 2),
			axis = .X,
			align = .Center,
			gap = 10,
			padding = {6, 0, 4, 0},
			corner_radius = 6,
			background = background,
			hover_background = hover_background,
			flags = {.Clickable},
		},
	)
	is_removed := false

	if ui.scope(row) {
		look.artwork_box(
			apple.to_artwork_url(song.artwork, look.to_artwork_pixels(QUEUE_COVER_POINTS)),
			QUEUE_COVER_POINTS,
			4,
			look.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("text", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(text) {
			is_hovered := ui.signal(row).is_hovered

			kit.scrolling_text("name", song.name, name_color, 13, .Medium, is_hovered = is_hovered)
			kit.scrolling_text(
				"artist",
				song.artist_name,
				kit.to_faded(kit.colors.base_content, 0.7),
				12,
				is_hovered = is_hovered,
			)
		}

		if !is_current && kit.is_mouse_in(row) {
			is_removed = kit.icon_button("remove", "xmark", 11, color = kit.to_faded(kit.colors.base_content, 0.7)).is_clicked
		}
	}

	if !is_removed && menus.apply_song_row_signal(ui.signal(row), song) {
		playback.play_queue_at(index)
	}

	return is_removed
}

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
			background = kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY),
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
	tint := kit.to_faded(kit.colors.primary, kit.SOFT_OPACITY)
	background: [4]f32 = tint if is_open else {}
	hover_background := tint if is_open else kit.to_faded(kit.colors.base_content, kit.HOVER_OPACITY)
	icon_color := kit.colors.primary if is_open else kit.to_faded(kit.colors.base_content, 0.7)
	label_color := kit.colors.primary if is_open else kit.colors.base_content
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
			background = background,
			hover_background = hover_background,
			press_background = kit.to_faded(kit.colors.base_content, kit.SELECTED_OPACITY),
			flags = {.Clickable},
		},
	)

	if ui.signal(tab).is_clicked do core.set_panel(panel)

	if ui.scope(tab) {
		kit.spacer()
		kit.icon_box("", symbol, 13, icon_color)
		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = label_color,
				font_size = kit.SMALL_TEXT_POINTS,
				font_weight = .Semibold,
			},
			label,
		)
		kit.spacer()
	}
}
