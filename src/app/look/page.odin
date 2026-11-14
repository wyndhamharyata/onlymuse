package look

import "core:fmt"
import "core:time"
import "om:app/core"
import "om:apple"
import "thor:app"
import "thor:kit"
import "thor:ui"

page_scroll :: proc(id: string) -> ^ui.Box {
	box := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.fill(),
			axis = .Y,
			gap = 20,
			padding = {PAGE_PADDING, 0, PAGE_PADDING, PAGE_PADDING},
			flags = {.Scroll, .Clip},
		},
	)
	core.keep_scroll(box)

	return box
}

// The panel's width as it was drawn last frame, the frame a page's size comes from, while it springs open or shut.
panel_width: f32

// How much wider the content becomes once the panel stops moving: negative while it opens.
to_panel_travel_left :: proc() -> f32 {
	target: f32 = 0
	if core.app.panel != .None do target = PANEL_WIDTH

	return panel_width - target
}

to_content_width :: proc(page: ^ui.Box) -> f32 {
	return page.size.x - page.style.padding.x - page.style.padding.z
}

to_phase_text :: proc(phase: apple.Phase) -> string {
	return "onlymuse could not reach Apple Music." if phase == .Failed else ""
}

build_phase :: proc(phase: apple.Phase, what: string) {
	if phase == .Failed {
		kit.description(to_phase_text(phase))
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
		ui.request_frame_after(time.Duration(-shown_seconds * f64(time.Second)))
		return
	}

	dot_count := 1 + int(shown_seconds / LOADING_DOT_SECONDS) % 3
	opacity := min(1, f32(shown_seconds / LOADING_FADE_SECONDS))

	ui.box("", {width = ui.fill(), height = ui.fill()})
	column := ui.box(
		"loading",
		{
			width = ui.fill(),
			axis = .Y,
			align = .Center,
			gap = 10,
			fade = 1 - opacity,
		},
	)

	if ui.scope(column) {
		kit.progress(0, .Base, ui.points(LOADING_BAR_WIDTH), is_indeterminate = true)

		all_dots := "..."
		dots_width := ui.points(kit.measure_text(all_dots, LOADING_TEXT_SIZE))
		label := ui.box("", {axis = .X})

		if ui.scope(label) {
			kit.description(fmt.tprintf("Loading %s", what), width = ui.Length{})
			kit.text(all_dots[:dot_count], kit.with_opacity(kit.colors.base_content, 0.7), LOADING_TEXT_SIZE, width = dots_width)
		}
	}

	ui.box("", {width = ui.fill(), height = ui.fill()})
	ui.request_frame()
}
