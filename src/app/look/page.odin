package look

import "core:fmt"
import "core:math"
import "core:time"
import "om:app/core"
import "om:apple"
import "thor:app"
import "thor:kit"
import "thor:platform"
import "thor:ui"

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

to_phase_text :: proc(phase: apple.Phase) -> string {
	return "onlymuse could not reach Apple Music." if phase == .Failed else ""
}

build_phase :: proc(phase: apple.Phase, what: string) {
	if phase == .Failed {
		kit.paragraph(to_phase_text(phase), kit.colors.dim)
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
	is_new_load := loading.started_at == {} || loading.asked_frame + 1 < app.frame_count
	if is_new_load do loading.started_at = time.tick_now()
	loading.asked_frame = app.frame_count

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
				height = ui.points(kit.BAR_TRACK_HEIGHT_POINTS),
			},
		)
		paint := new(kit.Bar_Paint, context.temp_allocator)
		paint^ = {first_ratio, first_ratio + LOADING_SEGMENT_RATIO}
		track.draw = kit.draw_bar
		track.data = paint

		all_dots := "..."
		dots_width := ui.points(kit.measure_text(all_dots, LOADING_TEXT_POINTS))
		label := ui.box("", {width = ui.fit_children(), height = ui.fit_children(), axis = .X})

		if ui.scope(label) {
			kit.text(
				fmt.tprintf("Loading %s", what),
				kit.colors.dim,
				LOADING_TEXT_POINTS,
				width = ui.fit_text(),
			)
			kit.text(all_dots[:dot_count], kit.colors.dim, LOADING_TEXT_POINTS, width = dots_width)
		}
	}

	ui.box("", {width = ui.fill(), height = ui.fill()})
	platform.request_frame()
}
