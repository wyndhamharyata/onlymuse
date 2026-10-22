package palette

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:apple"
import "om:ui"

// Groups with a title each. Returns the index of a clicked result, or -1.
@(private)
build_results :: proc() -> int {
	if len(palette.results) == 0 {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.faint,
				padding = {10, 6, 10, 8},
			},
			"Nothing matches. Apple Music is searched as you pause.",
		)
		return -1
	}

	list := ui.box(
		"palette list",
		{
			width = ui.fill(),
			height = ui.points(min(PALETTE_LIST_POINTS, palette_list_height())),
			axis = .Y,
			flags = {.Scroll, .Clip},
		},
	)
	picked := -1

	if ui.scope(list) {
		group := ""

		for result, index in palette.results {
			if result.group != group {
				group = result.group
				ui.box(
					"",
					{
						width = ui.fill(),
						height = ui.fit_text(),
						text_color = kit.colors.faint,
						font_size = 11,
						font_weight = .Bold,
						padding = {10, 8, 10, 4},
					},
					strings.to_upper(group, context.temp_allocator),
				)
			}

			if build_result_row(result, index) do picked = index
		}
	}

	return picked
}

@(private = "file")
palette_list_height :: proc() -> f32 {
	groups := 0
	group := ""

	for result in palette.results {
		if result.group != group {
			group = result.group
			groups += 1
		}
	}

	return f32(len(palette.results)) * PALETTE_ROW_POINTS + f32(groups) * 27
}

// Returns true when clicked. The pointer over a row selects it.
@(private = "file")
build_result_row :: proc(result: Palette_Result, index: int) -> bool {
	is_selected := index == palette.selected
	row := ui.box(
		fmt.tprintf("result %d", index),
		{
			width = ui.fill(),
			height = ui.points(PALETTE_ROW_POINTS),
			axis = .X,
			align = .Center,
			gap = 10,
			padding = {8, 0, 10, 0},
			corner_radius = 8,
			background = kit.to_accent_tint(core.app.accent) if is_selected else {},
			flags = {.Clickable},
		},
	)
	signal := ui.signal(row)

	// The pointer selects only when it moves, so a row under a still pointer leaves the arrow keys' choice.
	if signal.is_hovered && ui.mouse_position() != palette.last_mouse do palette.selected = index

	if ui.scope(row) {
		if result.artwork.url != "" {
			kit.artwork_box(
				apple.to_artwork_url(result.artwork, kit.to_artwork_pixels(26)),
				26,
				13 if result.is_round else 4,
				kit.to_placeholder(result.artwork, result.title, "music.note"),
			)
		} else {
			kit.icon_box(
				"",
				result.symbol if result.symbol != "" else "arrow.right",
				14,
				core.app.accent if is_selected else kit.colors.dim,
				{width = ui.points(26), height = ui.points(26)},
			)
		}

		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = 13.5,
				flags = {.Truncate_Text},
			},
			result.title,
		)
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.faint,
				font_size = 12,
				flags = {.Truncate_Text},
			},
			result.subtitle,
		)

		if result.shortcut != "" {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
					font_size = 12,
				},
				result.shortcut,
			)
		}

		if is_selected {
			ui.box(
				"",
				{
					width = ui.fit_text(),
					height = ui.fit_text(),
					text_color = core.app.accent,
					font_size = 13,
				},
				"↵",
			)
		}
	}

	return signal.is_clicked
}
