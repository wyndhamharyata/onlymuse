package kit

import "core:strings"
import "core:time"
import "om:platform"
import "om:ui"

// ---- The toast ----
TOAST_SECONDS :: 2.5

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

// Over the page, just above the player bar, fading out at the end.
build_toast :: proc() {
	if toast.text == "" do return

	seconds := f32(time.duration_seconds(time.tick_since(toast.shown_at)))
	if seconds > TOAST_SECONDS {
		delete(toast.text)
		toast.text = ""
		return
	}

	opacity := min(1, (TOAST_SECONDS - seconds) / 0.3)
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	width := measure_text(toast.text, 12.5) + 28
	ui.box("toast", {
		width         = ui.points(width),
		height        = ui.points(32),
		padding       = {14, 0, 14, 0},
		corner_radius = 10,
		background    = to_color(0x2c2c31ff),
		border_width  = 1,
		border_color  = to_color(0xffffff1c),
		text_color    = colors.text,
		font_size     = 12.5,
		fade          = 1 - opacity,
		position      = {(window_size.x - width) / 2, window_size.y - PLAYER_HEIGHT_POINTS - 44},
		flags         = {.Floating},
	}, toast.text)
	platform.request_frame()
}
