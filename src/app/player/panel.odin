package player

import "core:fmt"
import "om:app/core"
import "om:app/look"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "thor:images"
import "thor:kit"
import "thor:ui"

PANEL_PADDING :: 8

QUEUE_ROW_HEIGHT :: 52

QUEUE_COVER_SIZE :: 36

build_panel :: proc() -> bool {
	is_open := core.app.panel != .None
	width := ui.animate("panel width", look.PANEL_WIDTH if is_open else 0, kit.motion.normal)
	look.panel_width = width

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

			rules := kit.button("rules", "Rules", variant = .Soft, size = .Small)

			if rules.is_activated do playback.toggle_shuffle_rules(.Rules_Button)
			playback.build_shuffle_rules(.Rules_Button, rules.box)
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
	name_color := kit.colors.primary if is_current else kit.colors.base_content
	style := ui.Style {
		width         = ui.fill(),
		height        = ui.points(QUEUE_ROW_HEIGHT - 2),
		axis          = .X,
		align         = .Center,
		gap           = 10,
		padding       = {6, 0, 4, 0},
		corner_radius = 6,
	}
	if is_current {
		tint := kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
		style.bg, style.hover_bg = tint, tint
	}
	is_removed := false

	if kit.clickable(fmt.tprintf("queue_%d_%s", index, song.id), song.name, style) {
		signal := ui.here()

		look.artwork_box(
			apple.to_artwork_url(song.artwork, images.to_texture_size_px(ui.to_px(QUEUE_COVER_SIZE))),
			song.album_name,
			QUEUE_COVER_SIZE,
			4,
			look.to_placeholder(song.artwork, song.album_name),
		)

		text := ui.box("text", {width = ui.fill(), axis = .Y, gap = 2})

		if ui.scope(text) {
			is_hovered := signal.is_hovered

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

		// It shows under the pointer, and to the keyboard while the row or the button has focus. Tab moves
		// focus to last frame's button before this frame builds it, so that button is asked too.
		last_remove := ui.find_box("remove", signal.box)
		is_remove_focused := last_remove != nil && ui.signal(last_remove).is_focused
		is_remove_shown := !is_current && (signal.is_hovered || signal.is_focused || is_remove_focused)

		if is_remove_shown {
			is_removed = kit.button("remove", "Remove from Up Next", "xmark", variant = .Ghost, icon_size = 11, icon_color = kit.with_opacity(kit.colors.base_content, 0.7), is_label_hidden = true).is_activated
		}

		if !is_removed && menus.apply_song_row_signal(signal, song) do playback.play_queue_at(index)
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
	tabs := kit.segmented("panel_tabs", &selected, PANEL_TABS, tone = .Primary, width = ui.points(width))
	if tabs.is_changed do core.set_panel(.Lyrics if selected == "lyrics" else .Up_Next)
}
