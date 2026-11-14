package player

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

PANEL_PADDING :: 8

QUEUE_ROW_HEIGHT :: 52

QUEUE_COVER_SIZE :: 36

RULES_MENU_LEFT :: 240

build_panel :: proc() -> bool {
	is_open := core.app.panel != .None
	width := ui.animate("panel width", look.PANEL_WIDTH if is_open else 0, kit.motion.normal)

	if width < 1 do return false

	panel := ui.box(
		"panel",
		{
			width = ui.points(width),
			height = ui.fill(),
			axis = .Y,
			padding = {
				PANEL_PADDING,
				PANEL_PADDING,
				PANEL_PADDING,
				PANEL_PADDING,
			},
			gap = 4,
			bg = look.colors.panel,
			fade = 1 - width / look.PANEL_WIDTH,
			flags = {.Clip},
		},
	)
	is_moving := false
	inner_width: f32 = look.PANEL_WIDTH - 2 * PANEL_PADDING

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
			"shuffle_note",
			{
				width = ui.fill(),
				axis = .X,
				align = .Center,
				gap = 8,
				padding = {6, 2, 2, 6},
			},
		)

		if ui.scope(note_row) {
			kit.icon_box("shuffle", 11, kit.colors.primary)
			ui.box(
				"",
				{
					width = ui.fill(),
					text_color = kit.with_opacity(kit.colors.base_content, 0.7),
					font_size = 11.5,
					text_fit = .Wrap,
				},
				note_text,
			)

			rules := ui.box(
				"rules",
				{
					height = ui.points(22),
					padding = {8, 0, 8, 0},
					corner_radius = 6,
					bg = kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY),
					hover_bg = kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY),
					text_color = kit.colors.base_content,
					font_size = 11.5,
					font_weight = .Semibold,
					pointer = .Click,
				},
				"Rules",
			)

			if ui.signal(rules).is_activated {
				playback.open_shuffle_rules(
					{rules.rect.x - RULES_MENU_LEFT, rules.rect.w + 4},
				)
			}
		}
	}

	removed_row := -1
	defer if removed_row >= 0 do playback.remove_from_queue(removed_row)

	shown_count := len(playback.queue.songs) - playback.queue.index
	style := ui.Style {
		width  = ui.fill(),
		height = ui.fill(),
		gap    = 2,
		// The old empty spacer above the rows added a 2 point gap. This padding keeps that gap.
		padding = {0, 2, 0, 0},
		flags   = {.Scroll, .Clip},
	}

	if first, last, ok := kit.list("up_next", shown_count, QUEUE_ROW_HEIGHT - 2, style); ok {
		for offset in first ..< last {
			index := playback.queue.index + offset
			if build_queue_row(index) do removed_row = index
		}
	}
}

build_queue_row :: proc(index: int) -> bool {
	song := playback.queue.songs[index]
	is_current := index == playback.queue.index
	tint := kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
	bg: [4]f32 = tint if is_current else {}
	hover_bg := tint if is_current else kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY)
	name_color := kit.colors.primary if is_current else kit.colors.base_content
	row := ui.box(
		fmt.tprintf("queue_%d_%s", index, song.id),
		{
			width = ui.fill(),
			height = ui.points(QUEUE_ROW_HEIGHT - 2),
			axis = .X,
			align = .Center,
			gap = 10,
			padding = {6, 0, 4, 0},
			corner_radius = 6,
			bg = bg,
			hover_bg = hover_bg,
			pointer = .Click,
		},
	)
	is_removed := false

	if ui.scope(row) {
		look.artwork_box(
			apple.to_artwork_url(song.artwork, look.to_artwork_px(QUEUE_COVER_SIZE)),
			QUEUE_COVER_SIZE,
			4,
			look.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("text", {width = ui.fill(), axis = .Y, gap = 2})

		if ui.scope(text) {
			is_hovered := ui.signal(row).is_hovered

			kit.scrolling_text(
				"name",
				song.name,
				name_color,
				13,
				.Medium,
				is_sliding = is_hovered,
				pointer = .Passive,
			)
			kit.scrolling_text(
				"artist",
				song.artist_name,
				kit.with_opacity(kit.colors.base_content, 0.7),
				12,
				is_sliding = is_hovered,
				pointer = .Passive,
			)
		}

		if !is_current && ui.signal(row).is_hovered {
			is_removed = kit.button("remove", "Remove from Up Next", "xmark", variant = .Ghost, icon_size = 11, icon_color = kit.with_opacity(kit.colors.base_content, 0.7), is_label_hidden = true).is_activated
		}
	}

	if !is_removed && menus.apply_song_row_signal(ui.signal(row), song) {
		playback.play_queue_at(index)
	}

	return is_removed
}

PANEL_TABS := []kit.Option{{id = "up_next", label = "Up Next", icon = "list.bullet"}, {id = "lyrics", label = "Lyrics", icon = "quote.bubble"}}

build_panel_tabs :: proc(width: f32) {
	selected: string
	#partial switch core.app.panel {
	case .Up_Next:
		selected = "up_next"
	case .Lyrics:
		selected = "lyrics"
	}
	tabs := kit.segmented("panel_tabs", &selected, PANEL_TABS, width = ui.points(width))
	if tabs.is_changed do core.set_panel(.Lyrics if selected == "lyrics" else .Up_Next)
}
