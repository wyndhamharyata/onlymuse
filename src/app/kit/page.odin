package kit

import "core:fmt"
import "core:math"
import "core:time"
import "om:app/core"
import "om:apple"
import "om:platform"
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
	return "onlymuse could not reach Apple Music." if phase == .Failed else ""
}

build_phase :: proc(phase: apple.Phase, what: string) {
	if phase == .Failed {
		note(to_phase_text(phase))
		return
	}

	build_loading(what)
}

@(private = "file")
loading: struct {
	started_at:  time.Tick,
	asked_frame: int,
}

build_loading :: proc(what: string) {
	is_new_load := loading.started_at == {} || loading.asked_frame + 1 < core.app.frame_count
	if is_new_load do loading.started_at = time.tick_now()
	loading.asked_frame = core.app.frame_count

	elapsed_seconds := time.duration_seconds(time.tick_since(loading.started_at))
	shown_seconds := elapsed_seconds - LOADING_DELAY_SECONDS

	if shown_seconds < 0 {
		platform.request_frame_after(-shown_seconds)
		return
	}

	sweep := f32(1 - math.cos(2 * math.PI * shown_seconds / LOADING_SWEEP_SECONDS)) / 2
	first_ratio := sweep * (1 - LOADING_SEGMENT_RATIO)
	dot_count := 1 + int(shown_seconds / LOADING_DOT_SECONDS) % 3
	opacity := min(1, f32(shown_seconds / LOADING_FADE_SECONDS))

	ui.box("", {width = ui.fill(), height = ui.fill()})
	column := ui.box(
		"loading",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .Y,
			align = .Center,
			gap = 10,
			fade = 1 - opacity,
		},
	)

	if ui.scope(column) {
		track := ui.box(
			"",
			{
				width = ui.points(LOADING_BAR_WIDTH_POINTS),
				height = ui.points(BAR_TRACK_HEIGHT_POINTS),
			},
		)
		paint := new(Bar_Paint, context.temp_allocator)
		paint^ = {first_ratio, first_ratio + LOADING_SEGMENT_RATIO}
		track.draw = draw_bar
		track.data = paint

		all_dots := "..."
		dots_width := ui.points(measure_text(all_dots, LOADING_TEXT_POINTS))
		label := ui.box("", {width = ui.fit_children(), height = ui.fit_children(), axis = .X})

		if ui.scope(label) {
			text_box(
				fmt.tprintf("Loading %s", what),
				colors.dim,
				LOADING_TEXT_POINTS,
				width = ui.fit_text(),
			)
			text_box(all_dots[:dot_count], colors.dim, LOADING_TEXT_POINTS, width = dots_width)
		}
	}

	ui.box("", {width = ui.fill(), height = ui.fill()})
	platform.request_frame()
}
