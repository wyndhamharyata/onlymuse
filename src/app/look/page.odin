package look

import "core:fmt"
import "core:math"
import "core:time"
import "om:app/core"
import "om:apple"
import "thor:app"
import "thor:kit"
import "thor:render"
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

to_content_width :: proc(page: ^ui.Box) -> f32 {
	return page.size.x - page.style.padding.x - page.style.padding.z
}

to_phase_text :: proc(phase: apple.Phase) -> string {
	return "onlymuse could not reach Apple Music." if phase == .Failed else ""
}

build_phase :: proc(phase: apple.Phase, what: string) {
	if phase == .Failed {
		kit.text(to_phase_text(phase), kit.with_opacity(kit.colors.base_content, 0.7), is_wrapped = true)
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

	sweep := f32(1 - math.cos(2 * math.PI * shown_seconds / LOADING_SWEEP_SECONDS)) / 2
	first_ratio := sweep * (1 - LOADING_SEGMENT_RATIO)
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
		track := ui.box(
			"",
			{
				width = ui.points(LOADING_BAR_WIDTH),
				height = ui.points(LOADING_BAR_HEIGHT),
			},
		)
		paint := new([2]f32, context.temp_allocator)
		paint^ = {first_ratio, first_ratio + LOADING_SEGMENT_RATIO}
		track.draw = draw_loading_bar
		track.data = paint

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

LOADING_BAR_HEIGHT :: 4

// box.data points to two ratios. The bar fills the track between them.
draw_loading_bar :: proc(box: ^ui.Box, rect_px, clip_px: [4]f32, opacity: f32) {
	ratios := (cast(^[2]f32)box.data)^
	radius := (rect_px.w - rect_px.y) / 2
	filled := rect_px
	filled.x = rect_px.x + (rect_px.z - rect_px.x) * ratios[0]
	filled.z = rect_px.x + (rect_px.z - rect_px.x) * ratios[1]
	track_color := kit.with_opacity(kit.colors.base_content, kit.TRACK_OPACITY * opacity)
	render.push({rect = rect_px, color = track_color, corner_radius = radius, clip = clip_px})
	render.push({rect = filled, color = kit.with_opacity(kit.colors.base_content, opacity), corner_radius = radius, clip = clip_px})
}
