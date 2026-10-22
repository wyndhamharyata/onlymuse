// The look and the small parts every page builds with: theme, boxes, artwork, text fields,
// menus and toasts. The package imports only core from the window.
package kit

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:app/core"
import "om:font"
import "om:icon"
import "om:platform"
import "om:render"
import "om:ui"

// Apple's "2026-09-02" as "2 Sep 2026". "2026-09" and "2026" come out as "Sep 2026" and "2026".
to_date_text :: proc(date: string) -> string {
	MONTHS :: [12]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}

	// On the main thread, the memory of the temp allocator lasts until the next frame starts.
	parts := strings.split(date, "-", context.temp_allocator)
	if len(parts) < 2 do return date

	month, ok := strconv.parse_int(parts[1])
	if !ok || month < 1 || month > 12 do return date

	months := MONTHS
	if len(parts) < 3 do return fmt.tprintf("%s %s", months[month - 1], parts[0])

	// or_else gives 0 when the day does not parse.
	day := strconv.parse_int(parts[2]) or_else 0

	return fmt.tprintf("%d %s %s", day, months[month - 1], parts[0])
}

Icon_Paint :: struct {
	name:        string,
	size_points: f32,
	color:       [4]f32,
}

draw_icon :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	// box.data is an untyped pointer. cast reads it as the Icon_Paint that icon_box stored.
	paint := cast(^Icon_Paint)box.data
	color := paint.color
	color.a *= opacity
	icon.draw(paint.name, ui.to_pixels(paint.size_points), rect, clip, color)
}

// An SF Symbol in a box of its own size plus padding.
icon_box :: proc(
	id: string,
	name: string,
	size_points: f32,
	color: [4]f32,
	style: ui.Style = {},
) -> ^ui.Box {
	// An Odin parameter is read-only, so this copy is the one to change.
	style := style
	box_size := size_points + style.padding.x + style.padding.z
	if style.width.kind == .Points && style.width.value == 0 do style.width = ui.points(box_size)
	if style.height.kind == .Points && style.height.value == 0 do style.height = ui.points(box_size)

	box := ui.box(id, style)
	paint := new(Icon_Paint, context.temp_allocator)
	paint^ = {name, size_points, color}
	box.draw = draw_icon
	box.data = paint

	return box
}

// Returns true when clicked. A disabled button draws faint and takes no click.
icon_button :: proc(
	id: string,
	name: string,
	size_points: f32,
	color: [4]f32,
	is_enabled := true,
) -> bool {
	style := ui.Style {
		padding       = {4, 4, 4, 4},
		corner_radius = 6,
	}

	if is_enabled {
		style.hover_background = colors.hover
		style.press_background = colors.selected
		style.flags = {.Clickable}
	}

	box := icon_box(id, name, size_points, color if is_enabled else colors.faint, style)

	return ui.signal(box).is_clicked
}

text_box :: proc(
	text: string,
	color: [4]f32,
	font_size: f32 = 13,
	weight := font.Weight.Regular,
	flags: ui.Flags = {.Truncate_Text},
	width := ui.Size{.Fill, 1},
) -> ^ui.Box {
	return ui.box(
		"",
		{
			width = width,
			height = ui.fit_text(),
			text_color = color,
			font_size = font_size,
			font_weight = weight,
			flags = flags,
		},
		text,
	)
}

Bar_Paint :: struct {
	ratio: f32,
}

draw_bar :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Bar_Paint)box.data
	track_height := ui.to_pixels(4)
	top := (rect.y + rect.w - track_height) / 2
	track := [4]f32{rect.x, top, rect.z, top + track_height}
	filled := track
	filled.z = track.x + (track.z - track.x) * clamp(paint.ratio, 0, 1)
	radius := track_height / 2

	render.push(
		{
			rect = track,
			color = {colors.track.r, colors.track.g, colors.track.b, colors.track.a * opacity},
			corner_radius = radius,
			clip = clip,
		},
	)
	render.push(
		{
			rect = filled,
			color = {colors.text.r, colors.text.g, colors.text.b, colors.text.a * opacity},
			corner_radius = radius,
			clip = clip,
		},
	)
}

// A thin track to click or drag along. Returns the ratio shown, which follows the mouse while
// the button is down. is_set turns true once the person lets go of the mouse.
bar :: proc(id: string, ratio: f32, width: ui.Size) -> (shown_ratio: f32, is_set: bool) {
	box := ui.box(id, {width = width, height = ui.points(16), flags = {.Clickable}})
	signal := ui.signal(box)
	shown_ratio = ratio
	box_width := box.rect.z - box.rect.x

	if (signal.is_held || signal.is_clicked) && box_width > 0 {
		shown_ratio = clamp((ui.mouse_position().x - box.rect.x) / box_width, 0, 1)
	}

	paint := new(Bar_Paint, context.temp_allocator)
	paint.ratio = shown_ratio
	box.draw = draw_bar
	box.data = paint

	return shown_ratio, signal.is_clicked
}

to_clock_text :: proc(total_seconds: f64) -> string {
	whole_seconds := int(max(0, total_seconds))

	return fmt.tprintf("%d:%02d", whole_seconds / 60, whole_seconds % 60)
}

// The width of one line of text, in points.
measure_text :: proc(text: string, font_size: f32, weight := font.Weight.Regular) -> f32 {
	if text == "" do return 0

	return(
		font.shape(text, font.system_font(weight, ui.to_pixels(font_size))).size.x /
		ui.to_pixels(1) \
	)
}

// Takes the space left in a row, pushing what follows to the end.
spacer :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1)})
}

// The text slides at this speed, so a long title takes longer to show in full.
SLIDE_POINTS_PER_SECOND :: 40

// A row that only passes under the pointer in a scroll is gone before this. Nothing then slides.
SLIDE_REST_SECONDS :: 0.3

// @(private = "file") hides slide_start_seconds from other files.
@(private = "file")
slide_start_seconds: map[string]f64

// One line that ends in "…" when it does not fit. Resting under the pointer, it slides to show
// the rest. A clickable row passes in its hover, so the text never takes the row's click.
scrolling_text :: proc(
	id, text: string,
	color: [4]f32,
	font_size: f32,
	weight := font.Weight.Regular,
	is_clickable := false,
	is_hovered: Maybe(bool) = nil,
	width := ui.Size{.Fill, 1},
) -> ^ui.Box {
	flags: ui.Flags = {.Truncate_Text}
	if is_clickable do flags += {.Clickable}
	if is_hovered == nil && !is_clickable do flags += {.Hoverable}

	box := ui.box(
		id,
		{
			width = width,
			height = ui.fit_text(),
			text_color = color,
			font_size = font_size,
			font_weight = weight,
			flags = flags,
		},
		text,
	)

	key := fmt.aprint(id, text)
	// defer deletes key when this procedure returns, on every path.
	defer delete(key)

	// .? or_else takes the caller's hover when it passed one, else the box's own.
	if !(is_hovered.? or_else ui.signal(box).is_hovered) {
		if key in slide_start_seconds {
			delete_key_and_value(&slide_start_seconds, key)
		}

		return box
	}

	now_seconds := f64(time.to_unix_nanoseconds(time.now())) / 1e9
	if key not_in slide_start_seconds do slide_start_seconds[strings.clone(key)] = now_seconds

	rested_seconds := now_seconds - slide_start_seconds[key] - SLIDE_REST_SECONDS

	if rested_seconds < 0 {
		platform.request_frame_after(-rested_seconds)
		return box
	}

	// The full line, measured against the box's width from last frame.
	full := font.shape(text, font.system_font(weight, ui.to_pixels(font_size)))
	overflow := full.size.x / ui.to_pixels(1) - (box.rect.z - box.rect.x)
	if overflow <= 0 do return box

	box.style.flags -= {.Truncate_Text}
	box.style.text_offset = min(overflow, f32(rested_seconds) * SLIDE_POINTS_PER_SECOND)
	if box.style.text_offset < overflow do platform.request_frame()

	return box
}

@(private = "file")
delete_key_and_value :: proc(from: ^map[string]f64, key: string) {
	// delete_key hands back the map's own copy of the key, which is the one to free.
	stored_key, _ := delete_key(from, key)
	delete(stored_key)
}

// Whether the pointer is over the box, as of last frame, even when a button in it has the hover.
is_mouse_in :: proc(box: ^ui.Box) -> bool {
	mouse := ui.mouse_position()

	return(
		mouse.x >= box.rect.x &&
		mouse.x < box.rect.z &&
		mouse.y >= box.rect.y &&
		mouse.y < box.rect.w \
	)
}

// A rounded pill that is on or off. Returns true when clicked.
toggle_chip :: proc(label: string, is_on: bool) -> bool {
	tint := to_accent_tint(core.app.accent)
	chip := ui.box(
		label,
		{
			width = ui.fit_text(),
			height = ui.points(24),
			padding = {10, 0, 10, 0},
			corner_radius = 12,
			background = tint if is_on else colors.field,
			hover_background = tint if is_on else colors.hover,
			border_width = 1 if is_on else 0,
			border_color = {core.app.accent.r, core.app.accent.g, core.app.accent.b, 0.35},
			text_color = core.app.accent if is_on else colors.dim,
			font_size = 12,
			font_weight = .Semibold,
			flags = {.Clickable},
		},
		label,
	)

	return ui.signal(chip).is_clicked
}
