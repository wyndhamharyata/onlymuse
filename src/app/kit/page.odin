package kit

import "om:app/core"
import "om:apple"
import "om:ui"

page_scroll :: proc(id: string) -> ^ui.Box {
	box := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.fill(),
			axis = .Y,
			gap = 20,
			padding = {PAGE_PADDING_POINTS, 0, PAGE_PADDING_POINTS, PAGE_PADDING_POINTS},
			flags = {.Scroll, .Clip},
		},
	)
	core.keep_scroll(box)

	return box
}

to_content_width :: proc(page: ^ui.Box) -> f32 {
	return page.size.x - page.style.padding.x - page.style.padding.z
}

page_heading :: proc(title: string) {
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			text_color = colors.text,
			font_size = 28,
			font_weight = .Bold,
			flags = {.Truncate_Text},
		},
		title,
	)
}

note :: proc(text: string) {
	ui.box(
		"",
		{width = ui.fill(), height = ui.fit_text(), text_color = colors.dim, flags = {.Wrap_Text}},
		text,
	)
}

PRIMARY_BUTTON_HOVER_ALPHA :: 0.85

BUTTON_HOVER_ALPHA :: 0.14

action_button :: proc(label, symbol: string, is_primary: bool, symbol_color: [4]f32 = {}) -> bool {
	background := core.app.accent if is_primary else colors.field
	hover := background
	hover.a = PRIMARY_BUTTON_HOVER_ALPHA if is_primary else BUTTON_HOVER_ALPHA
	color := colors.white if is_primary else colors.text

	button := ui.box(
		label,
		{
			width = ui.fit_children(),
			height = ui.points(BUTTON_HEIGHT_POINTS),
			axis = .X,
			align = .Center,
			gap = 6,
			padding = {14, 0, 16, 0},
			corner_radius = 8,
			background = background,
			hover_background = hover,
			flags = {.Clickable},
		},
	)

	if ui.scope(button) {
		icon_box("", symbol, 12, symbol_color if symbol_color.a > 0 else color)
		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = color,
				font_weight = .Semibold,
			},
			label,
		)
	}

	return ui.signal(button).is_clicked
}

BENCH_POINTS_PER_FRAME :: 30

run_bench_scroll :: proc(list: ^ui.Box) {
	if !core.app.is_bench do return

	max_scroll := list.content_size.y - list.size.y

	if max_scroll <= 0 do return

	is_at_end := list.scroll >= max_scroll || (list.scroll <= 0 && core.app.bench_direction < 0)
	if is_at_end do core.app.bench_direction *= -1

	ui.set_scroll(list, list.scroll + BENCH_POINTS_PER_FRAME * core.app.bench_direction)
}

to_phase_text :: proc(phase: apple.Phase) -> string {
	return "onlymuse could not reach Apple Music." if phase == .Failed else "Loading…"
}
