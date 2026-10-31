package palette

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:apple"
import "om:ui"

GROUP_TITLE_HEIGHT_POINTS :: 27

ROW_ARTWORK_POINTS :: 26

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
			"Nothing matches. The palette searches Apple Music when you stop typing.",
		)
		return -1
	}

	list := ui.box(
		"palette list",
		{
			width = ui.fill(),
			height = ui.points(
				min(PALETTE_LIST_MAX_HEIGHT_POINTS, to_list_height_points(palette.results)),
			),
			axis = .Y,
			flags = {.Scroll, .Clip},
		},
	)
	picked := -1

	if palette.should_reset_scroll {
		palette.should_reset_scroll = false
		ui.set_scroll(list, 0)
	} else if palette.field.step != 0 {
		scroll_to_selected(list)
	}

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
scroll_to_selected :: proc(list: ^ui.Box) {
	top := to_row_top_points(palette.selected_index)
	bottom := top + PALETTE_ROW_HEIGHT_POINTS
	height := min(PALETTE_LIST_MAX_HEIGHT_POINTS, to_list_height_points(palette.results))
	view_top := list.scroll_target
	view_bottom := view_top + height

	if top < view_top {
		ui.set_scroll(list, top)
	} else if bottom > view_bottom {
		ui.set_scroll(list, bottom - height)
	}
}

@(private = "file")
to_row_top_points :: proc(index: int) -> f32 {
	top: f32
	group := ""

	for result, result_index in palette.results {
		if result.group != group {
			group = result.group
			top += GROUP_TITLE_HEIGHT_POINTS
		}

		if result_index == index do return top

		top += PALETTE_ROW_HEIGHT_POINTS
	}

	return top
}

@(private = "file")
to_list_height_points :: proc(results: []Palette_Result) -> f32 {
	group_count := 0
	group := ""

	for result in results {
		if result.group != group {
			group = result.group
			group_count += 1
		}
	}

	return(
		f32(len(results)) * PALETTE_ROW_HEIGHT_POINTS +
		f32(group_count) * GROUP_TITLE_HEIGHT_POINTS \
	)
}

@(private = "file")
build_result_row :: proc(result: Palette_Result, index: int) -> bool {
	is_selected := index == palette.selected_index
	row := ui.box(
		fmt.tprintf("result %d", index),
		{
			width = ui.fill(),
			height = ui.points(PALETTE_ROW_HEIGHT_POINTS),
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
	has_pointer_moved := ui.mouse_position() != palette.last_mouse_position

	if signal.is_hovered && has_pointer_moved {
		palette.selected_index = index
	}

	if ui.scope(row) {
		if result.artwork.url != "" {
			kit.artwork_box(
				apple.to_artwork_url(result.artwork, kit.to_artwork_pixels(ROW_ARTWORK_POINTS)),
				ROW_ARTWORK_POINTS,
				ROW_ARTWORK_POINTS / 2 if result.is_round else 4,
				kit.to_placeholder(result.artwork, result.title),
			)
		} else {
			kit.icon_box(
				"",
				result.symbol if result.symbol != "" else "arrow.right",
				14,
				core.app.accent if is_selected else kit.colors.dim,
				{width = ui.points(ROW_ARTWORK_POINTS), height = ui.points(ROW_ARTWORK_POINTS)},
			)
		}

		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = kit.colors.faint if result.is_disabled else kit.colors.text,
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

		if is_selected && !result.is_disabled {
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

	return signal.is_clicked && !result.is_disabled
}
