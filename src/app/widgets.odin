package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import MTL "vendor:darwin/Metal"
import "om:apple"
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
	// A URL of Apple's or a file path. Empty for the placeholder alone.
	source:      string,
	size_pixels: int,
	symbol:      string,
	// The symbol shows until the picture fades in over it.
	symbol_points: f32,
	symbol_color:  [4]f32,
	// A picture of another shape fills the box and is cropped. This is where its crop starts across
	// the height, from 0 for the top to 1 for the bottom.
	focus_y:       f32,
}

draw_artwork :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Artwork_Paint)box.data
	texture: ^MTL.Texture
	image_opacity: f32
	if paint.source != "" do texture, image_opacity = image.find(paint.source, paint.size_pixels)

	if image_opacity < 1 && paint.symbol != "" {
		color := paint.symbol_color
		color.a *= opacity * (1 - image_opacity)
		icon.draw(paint.symbol, ui.to_pixels(paint.symbol_points), rect, clip, color)
	}

	if texture == nil do return

	render.push({rect = rect, uv = to_fill_uv(rect, texture, paint.focus_y), color = {1, 1, 1, opacity * image_opacity}, corner_radius = ui.to_pixels(box.style.corner_radius), clip = clip, kind = .Image}, texture)
}

// The part of the texture that fills rect at its own proportions.
@(private = "file")
to_fill_uv :: proc(rect: [4]f32, texture: ^MTL.Texture, focus_y: f32) -> [4]f32 {
	rect_ratio := (rect.z - rect.x) / (rect.w - rect.y)
	texture_ratio := f32(texture->width()) / f32(texture->height())
	if rect_ratio <= 0 || abs(rect_ratio - texture_ratio) < 0.01 do return {0, 0, 1, 1}

	if texture_ratio > rect_ratio {
		width := rect_ratio / texture_ratio
		left := (1 - width) / 2

		return {left, 0, left + width, 1}
	}

	height := texture_ratio / rect_ratio
	top := (1 - height) * focus_y

	return {0, top, 1, top + height}
}

// What shows while a picture loads: a gradient in the picture's own colours, or in two colours picked
// from the name when Apple sends none, with a symbol of what it is.
Placeholder :: struct {
	top, bottom: [4]f32,
	symbol:      string,
	mark:        [4]f32,
}

// Catalog artwork brings its colours, so the gradient previews the cover. Library artwork has none, so
// the name picks the hues, and the same album gets the same colours everywhere.
to_placeholder :: proc(artwork: apple.Artwork, seed: string, symbol := "music.note") -> Placeholder {
	if background, ok := parse_hex_color(artwork.bg_color); ok {
		ink, has_ink := parse_hex_color(artwork.text_color1)
		if !has_ink do ink = colors.text

		return {top = mix_color(background, ink, 0.18), bottom = mix_color(background, {0, 0, 0, 1}, 0.25), symbol = symbol, mark = {ink.r, ink.g, ink.b, 0.5}}
	}

	hash := u32(2166136261)
	for character in transmute([]u8)seed do hash = (hash ~ u32(character)) * 16777619

	hue := f32(hash % 360)
	turn := 30 + f32((hash >> 9) % 70)

	return {top = to_color_from_hsl(hue, 0.34, 0.33), bottom = to_color_from_hsl(hue + turn, 0.3, 0.19), symbol = symbol, mark = {1, 1, 1, 0.28}}
}

// A square of artwork over its placeholder. An empty source shows the placeholder only.
artwork_box :: proc(source: string, size_points: f32, radius_points: f32, placeholder: Placeholder) -> ^ui.Box {
	return artwork_rect_box(source, {size_points, size_points}, radius_points, placeholder)
}

artwork_rect_box :: proc(source: string, size_points: [2]f32, radius_points: f32, placeholder: Placeholder) -> ^ui.Box {
	box := ui.box("", {
		width          = ui.points(size_points.x),
		height         = ui.points(size_points.y),
		corner_radius  = radius_points,
		background     = placeholder.top,
		end_background = placeholder.bottom,
		gradient       = {0, 1},
	})

	if source == "" && placeholder.symbol == "" do return box

	paint := new(Artwork_Paint, context.temp_allocator)
	paint^ = {
		source        = source,
		size_pixels   = int(ui.to_pixels(max(size_points.x, size_points.y))),
		symbol        = placeholder.symbol,
		// In steps of 4, so a tile resizing with the panel reuses a few sizes of its symbol.
		symbol_points = max(8, math.round(min(size_points.x, size_points.y) * 0.3 / 4) * 4),
		symbol_color  = placeholder.mark,
		focus_y       = 0.5,
	}
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

// The width of one line of text, in points.
measure_text :: proc(text: string, font_size: f32, weight := font.Weight.Regular) -> f32 {
	if text == "" do return 0

	return font.shape(text, font.system_font(weight, ui.to_pixels(font_size))).size.x / ui.to_pixels(1)
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
// Inside a clickable row, the row's hover is passed in, so the text never takes the row's click.
scrolling_text :: proc(id, text: string, color: [4]f32, font_size: f32, weight := font.Weight.Regular, is_clickable := false, is_hovered: Maybe(bool) = nil, width := ui.Size{.Fill, 1}) -> ^ui.Box {
	flags: ui.Flags = {.Truncate_Text}
	if is_clickable do flags += {.Clickable}
	if is_hovered == nil && !is_clickable do flags += {.Hoverable}

	box := ui.box(id, {width = width, height = ui.fit_text(), text_color = color, font_size = font_size, font_weight = weight, flags = flags}, text)
	key := fmt.aprint(id, text)
	defer delete(key)

	if !(is_hovered.? or_else ui.signal(box).is_hovered) {
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

// Whether the pointer is over the box, as of last frame, even when a button inside it has the hover.
is_mouse_in :: proc(box: ^ui.Box) -> bool {
	mouse := ui.mouse_position()

	return mouse.x >= box.rect.x && mouse.x < box.rect.z && mouse.y >= box.rect.y && mouse.y < box.rect.w
}

// A rounded pill that is on or off. Returns true when clicked.
toggle_chip :: proc(label: string, is_on: bool) -> bool {
	tint := to_accent_tint(app.accent)
	chip := ui.box(label, {
		width            = ui.fit_text(),
		height           = ui.points(24),
		padding          = {10, 0, 10, 0},
		corner_radius    = 12,
		background       = tint if is_on else colors.field,
		hover_background = tint if is_on else colors.hover,
		border_width     = 1 if is_on else 0,
		border_color     = {app.accent.r, app.accent.g, app.accent.b, 0.35},
		text_color       = app.accent if is_on else colors.dim,
		font_size        = 12,
		font_weight      = .Semibold,
		flags            = {.Clickable},
	}, label)

	return ui.signal(chip).is_clicked
}
