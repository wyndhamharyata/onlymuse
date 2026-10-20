package app

import "core:fmt"
import "core:strings"
import "core:time"
import "om:font"
import "om:icon"
import "om:image"
import "om:platform"
import "om:render"
import "om:ui"

Icon_Paint :: struct {
	name:        string,
	size_points: f32,
	color:       [4]f32,
}

draw_icon :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Icon_Paint)box.data
	color := paint.color
	color.a *= opacity
	icon.draw(paint.name, ui.to_pixels(paint.size_points), rect, clip, color)
}

// An SF Symbol in a box of its own size plus padding.
icon_box :: proc(id: string, name: string, size_points: f32, color: [4]f32, style: ui.Style = {}) -> ^ui.Box {
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
icon_button :: proc(id: string, name: string, size_points: f32, color: [4]f32, is_enabled := true) -> bool {
	style := ui.Style{padding = {4, 4, 4, 4}, corner_radius = 6}
	if is_enabled {
		style.hover_background = colors.hover
		style.press_background = colors.selected
		style.flags = {.Clickable}
	}

	box := icon_box(id, name, size_points, color if is_enabled else colors.faint, style)

	return ui.signal(box).is_clicked
}

Artwork_Paint :: struct {
	// A URL of Apple's or a file path.
	source:      string,
	size_pixels: int,
}

draw_artwork :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Artwork_Paint)box.data
	texture, image_opacity := image.find(paint.source, paint.size_pixels)

	if texture == nil do return

	render.push({rect = rect, uv = {0, 0, 1, 1}, color = {1, 1, 1, opacity * image_opacity}, corner_radius = ui.to_pixels(box.style.corner_radius), clip = clip, kind = .Image}, texture)
}

// A square of artwork with a grey card behind it until it loads. An empty source shows the card only.
artwork_box :: proc(source: string, size_points: f32, radius_points: f32) -> ^ui.Box {
	return artwork_rect_box(source, {size_points, size_points}, radius_points, colors.card)
}

artwork_rect_box :: proc(source: string, size_points: [2]f32, radius_points: f32, card: [4]f32) -> ^ui.Box {
	box := ui.box("", {width = ui.points(size_points.x), height = ui.points(size_points.y), corner_radius = radius_points, background = card})

	if source == "" do return box

	paint := new(Artwork_Paint, context.temp_allocator)
	paint^ = {source, int(ui.to_pixels(max(size_points.x, size_points.y)))}
	box.draw = draw_artwork
	box.data = paint

	return box
}

text_box :: proc(text: string, color: [4]f32, font_size: f32 = 13, weight := font.Weight.Regular, flags: ui.Flags = {.Truncate_Text}, width := ui.Size{.Fill, 1}) -> ^ui.Box {
	return ui.box("", {width = width, height = ui.fit_text(), text_color = color, font_size = font_size, font_weight = weight, flags = flags}, text)
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
	render.push({rect = track, color = {colors.track.r, colors.track.g, colors.track.b, colors.track.a * opacity}, corner_radius = radius, clip = clip})
	render.push({rect = filled, color = {colors.text.r, colors.text.g, colors.text.b, colors.text.a * opacity}, corner_radius = radius, clip = clip})
}

// A thin track to click or drag along. Returns the ratio shown, which follows the mouse while held, and
// is_set once the mouse is let go.
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

// Takes the space left in a row, pushing what follows to the end.
spacer :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1)})
}

// The text slides at this speed, so a long title takes longer to show in full.
SLIDE_POINTS_PER_SECOND :: 40
// A row that only passes under the pointer during a scroll is gone before this, and nothing slides.
SLIDE_REST_SECONDS :: 0.3

@(private = "file")
slides: map[string]f64

// One line that ends in "…" when it does not fit. Resting under the pointer, it slides to show the rest.
scrolling_text :: proc(id, text: string, color: [4]f32, font_size: f32, weight := font.Weight.Regular, is_clickable := false) -> ^ui.Box {
	box := ui.box(id, {width = ui.fill(), height = ui.fit_text(), text_color = color, font_size = font_size, font_weight = weight, flags = {.Truncate_Text, .Clickable if is_clickable else .Hoverable}}, text)
	key := fmt.aprint(id, text)
	defer delete(key)

	if !ui.signal(box).is_hovered {
		if key in slides {
			delete_key_and_value(&slides, key)
		}
		return box
	}

	now := f64(time.to_unix_nanoseconds(time.now())) / 1e9
	if key not_in slides do slides[strings.clone(key)] = now

	rested := now - slides[key] - SLIDE_REST_SECONDS
	if rested < 0 {
		platform.request_frame_after(-rested)
		return box
	}

	// The full line, measured against the box's width from last frame.
	full := font.shape(text, font.system_font(weight, ui.to_pixels(font_size)))
	overflow := full.size.x / ui.to_pixels(1) - (box.rect.z - box.rect.x)
	if overflow <= 0 do return box

	box.style.flags -= {.Truncate_Text}
	box.style.text_offset = min(overflow, f32(rested) * SLIDE_POINTS_PER_SECOND)
	if box.style.text_offset < overflow do platform.request_frame()

	return box
}

@(private = "file")
delete_key_and_value :: proc(m: ^map[string]f64, key: string) {
	stored_key, _ := delete_key(m, key)
	delete(stored_key)
}
