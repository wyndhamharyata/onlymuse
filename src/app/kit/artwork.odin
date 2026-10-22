package kit

import "core:math"
import "om:apple"
import "om:icon"
import "om:image"
import "om:render"
import "om:ui"
import MTL "vendor:darwin/Metal"

// Artwork is asked for in steps of this many pixels, so a resized window reuses the saved files.
ARTWORK_STEP_PIXELS :: 100

to_artwork_pixels :: proc(size_points: f32) -> int {
	pixels := int(ui.to_pixels(size_points))

	return (pixels + ARTWORK_STEP_PIXELS - 1) / ARTWORK_STEP_PIXELS * ARTWORK_STEP_PIXELS
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
	if paint.source != "" {
		texture, image_opacity = image.find(paint.source, paint.size_pixels, to_crop(rect, paint.focus_y))
	}

	if image_opacity < 1 && paint.symbol != "" {
		color := paint.symbol_color
		color.a *= opacity * (1 - image_opacity)
		icon.draw(paint.symbol, ui.to_pixels(paint.symbol_points), rect, clip, color)
	}

	if texture == nil do return

	render.push({rect = rect, uv = to_fill_uv(rect, texture, paint.focus_y), color = {1, 1, 1, opacity * image_opacity}, corner_radius = ui.to_pixels(box.style.corner_radius), clip = clip, kind = .Image}, texture)
}

// The box's shape, rounded down to a quarter, so a box that resizes reuses a few textures. A texture a
// little taller than the box is cut the rest of the way by to_fill_uv.
@(private = "file")
to_crop :: proc(rect: [4]f32, focus_y: f32) -> image.Crop {
	height := rect.w - rect.y
	if height <= 0 do return {}

	// The 0.01 absorbs float noise: at most zooms a square box comes out 0.9999997 wide for each 1 high, and a
	// plain floor would flip it to 0.75 on some frames and back.
	return {math.floor((rect.z - rect.x) / height * 4 + 0.01) / 4, focus_y}
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
