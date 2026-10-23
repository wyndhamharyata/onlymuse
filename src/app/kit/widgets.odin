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

	parts := strings.split(date, "-", context.temp_allocator)
	if len(parts) < 2 do return date

	month, ok := strconv.parse_int(parts[1])
	if !ok || month < 1 || month > 12 do return date

	months := MONTHS
	if len(parts) < 3 do return fmt.tprintf("%s %s", months[month - 1], parts[0])

	day := strconv.parse_int(parts[2]) or_else 0

	return fmt.tprintf("%d %s %s", day, months[month - 1], parts[0])
}

Icon_Paint :: struct {
	name:        string,
	size_points: f32,
	color:       [4]f32,
}

draw_icon :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Icon_Paint)box.data
	color := to_faded(paint.color, opacity)
	icon.draw(paint.name, ui.to_pixels(paint.size_points), rect, clip, color)
}

icon_box :: proc(
	id: string,
	symbol: string,
	size_points: f32,
	color: [4]f32,
	style: ui.Style = {},
) -> ^ui.Box {
	style := style
	box_size := size_points + style.padding.x + style.padding.z
	if is_size_unset(style.width) do style.width = ui.points(box_size)
	if is_size_unset(style.height) do style.height = ui.points(box_size)

	box := ui.box(id, style)
	paint := new(Icon_Paint, context.temp_allocator)
	paint^ = {symbol, size_points, color}
	box.draw = draw_icon
	box.data = paint

	return box
}

@(private = "file")
is_size_unset :: proc(size: ui.Size) -> bool {
	return size.kind == .Points && size.value == 0
}

icon_button :: proc(
	id: string,
	symbol: string,
	size_points: f32,
	color: [4]f32,
	is_enabled := true,
) -> bool {
	style := ui.Style {
		padding       = ICON_BUTTON_PADDING_POINTS,
		corner_radius = 6,
	}

	if is_enabled {
		style.hover_background = colors.hover
		style.press_background = colors.selected
		style.flags = {.Clickable}
	}

	box := icon_box(id, symbol, size_points, color if is_enabled else colors.faint, style)

	return ui.signal(box).is_clicked
}

text_box :: proc(
	text: string,
	color: [4]f32,
	font_size: f32 = 13,
	weight := font.Weight.Regular,
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
			flags = {.Truncate_Text},
		},
		text,
	)
}

Bar_Paint :: struct {
	first_ratio, last_ratio: f32,
}

BAR_TRACK_HEIGHT_POINTS :: 4

draw_bar :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Bar_Paint)box.data
	track_height := ui.to_pixels(BAR_TRACK_HEIGHT_POINTS)
	top := (rect.y + rect.w - track_height) / 2
	track := [4]f32{rect.x, top, rect.z, top + track_height}
	track_width := track.z - track.x
	filled := track
	filled.x = track.x + track_width * clamp(paint.first_ratio, 0, 1)
	filled.z = track.x + track_width * clamp(paint.last_ratio, 0, 1)
	radius := track_height / 2

	render.push(
		{
			rect = track,
			color = to_faded(colors.track, opacity),
			corner_radius = radius,
			clip = clip,
		},
	)
	render.push(
		{
			rect = filled,
			color = to_faded(colors.text, opacity),
			corner_radius = radius,
			clip = clip,
		},
	)
}

bar :: proc(id: string, ratio: f32, width: ui.Size) -> (shown_ratio: f32, is_set: bool) {
	box := ui.box(id, {width = width, height = ui.points(16), flags = {.Clickable}})
	signal := ui.signal(box)
	shown_ratio = ratio
	box_width := box.rect.z - box.rect.x
	is_following_mouse := (signal.is_held || signal.is_clicked) && box_width > 0

	if is_following_mouse {
		shown_ratio = clamp((ui.mouse_position().x - box.rect.x) / box_width, 0, 1)
	}

	paint := new(Bar_Paint, context.temp_allocator)
	paint.last_ratio = shown_ratio
	box.draw = draw_bar
	box.data = paint

	return shown_ratio, signal.is_clicked
}

to_clock_text :: proc(total_seconds: f64) -> string {
	whole_seconds := int(max(0, total_seconds))

	return fmt.tprintf("%d:%02d", whole_seconds / 60, whole_seconds % 60)
}

measure_text :: proc(text: string, font_size: f32, weight := font.Weight.Regular) -> f32 {
	if text == "" do return 0

	return(
		font.shape(text, font.system_font(weight, ui.to_pixels(font_size))).size_pixels.x /
		ui.to_pixels(1) \
	)
}

spacer :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1)})
}

SLIDE_POINTS_PER_SECOND :: 40

SLIDE_REST_SECONDS :: 0.3

@(private = "file")
slide_start_seconds: map[string]f64

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
	defer delete(key)

	is_under_pointer := is_hovered.? or_else ui.signal(box).is_hovered

	if !is_under_pointer {
		stored_key, _ := delete_key(&slide_start_seconds, key)
		delete(stored_key)
		return box
	}

	now_seconds := f64(time.to_unix_nanoseconds(time.now())) / 1e9
	if key not_in slide_start_seconds do slide_start_seconds[strings.clone(key)] = now_seconds

	rested_seconds := now_seconds - slide_start_seconds[key] - SLIDE_REST_SECONDS

	if rested_seconds < 0 {
		platform.request_frame_after(-rested_seconds)
		return box
	}

	overflow := measure_text(text, font_size, weight) - (box.rect.z - box.rect.x)
	if overflow <= 0 do return box

	box.style.flags -= {.Truncate_Text}
	box.style.text_offset = min(overflow, f32(rested_seconds) * SLIDE_POINTS_PER_SECOND)
	if box.style.text_offset < overflow do platform.request_frame()

	return box
}

is_mouse_in :: proc(box: ^ui.Box) -> bool {
	mouse := ui.mouse_position()

	return(
		mouse.x >= box.rect.x &&
		mouse.x < box.rect.z &&
		mouse.y >= box.rect.y &&
		mouse.y < box.rect.w \
	)
}

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
