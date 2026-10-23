package kit

import "core:strings"
import "core:time"
import "om:platform"
import "om:ui"

TOAST_SECONDS :: 2.5

TOAST_FADE_SECONDS :: 0.3

TOAST_PADDING_POINTS :: 14

TOAST_MARGIN_POINTS :: 12

@(private = "file")
toast: struct {
	text:     string,
	shown_at: time.Tick,
}

show_toast :: proc(text: string) {
	delete(toast.text)
	toast.text = strings.clone(text)
	toast.shown_at = time.tick_now()
}

build_toast :: proc() {
	if toast.text == "" do return

	seconds := f32(time.duration_seconds(time.tick_since(toast.shown_at)))

	if seconds > TOAST_SECONDS {
		delete(toast.text)
		toast.text = ""
		return
	}

	opacity := min(1, (TOAST_SECONDS - seconds) / TOAST_FADE_SECONDS)
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	width := measure_text(toast.text, SMALL_TEXT_POINTS) + 2 * TOAST_PADDING_POINTS
	top := window_size.y - PLAYER_HEIGHT_POINTS - TOAST_MARGIN_POINTS - BUTTON_HEIGHT_POINTS

	ui.box(
		"toast",
		{
			width = ui.points(width),
			height = ui.points(BUTTON_HEIGHT_POINTS),
			padding = {TOAST_PADDING_POINTS, 0, TOAST_PADDING_POINTS, 0},
			corner_radius = 10,
			background = colors.toast,
			border_width = 1,
			border_color = colors.popover_border,
			text_color = colors.text,
			font_size = SMALL_TEXT_POINTS,
			fade = 1 - opacity,
			position = {(window_size.x - width) / 2, top},
			flags = {.Floating},
		},
		toast.text,
	)
	platform.request_frame()
}
