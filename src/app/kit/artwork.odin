package kit

import "core:math"
import "om:apple"
import "om:icon"
import "om:image"
import "om:render"
import "om:ui"
import MTL "vendor:darwin/Metal"

// The app asks for artwork in steps of this many pixels, so a resized window reuses saved files.
ARTWORK_STEP_PIXELS :: 100

to_artwork_pixels :: proc(size_points: f32) -> int {
	pixels := int(ui.to_pixels(size_points))

	return (pixels + ARTWORK_STEP_PIXELS - 1) / ARTWORK_STEP_PIXELS * ARTWORK_STEP_PIXELS
}

Artwork_Paint :: struct {
	// A URL of Apple's or a file path. The source is empty for the placeholder alone.
	source:        string,
	size_pixels:   int,
	symbol:        string,
	// The symbol shows until the picture fades in over it.
	symbol_points: f32,
	symbol_color:  [4]f32,
	// A picture of other proportions fills the box, which crops its edges. This is where the
	// crop starts across the height, from 0 for the top to 1 for the bottom.
	focus_y:       f32,
}

draw_artwork :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	// cast reads box.data, an untyped pointer, as the Artwork_Paint from artwork_rect_box.
	paint := cast(^Artwork_Paint)box.data
	texture: ^MTL.Texture
	image_opacity: f32

	if paint.source != "" {
		texture, image_opacity = image.watch(
			paint.source,
			paint.size_pixels,
			to_crop(rect, paint.focus_y),
		)
	}

	if image_opacity < 1 && paint.symbol != "" {
		color := paint.symbol_color
		color.a *= opacity * (1 - image_opacity)
		icon.draw(paint.symbol, ui.to_pixels(paint.symbol_points), rect, clip, color)
	}

	if texture == nil do return

	render.push(
		{
			rect = rect,
			uv = to_fill_uv(rect, texture, paint.focus_y),
			color = {1, 1, 1, opacity * image_opacity},
			corner_radius = ui.to_pixels(box.style.corner_radius),
			clip = clip,
			kind = .Image,
		},
		texture,
	)
}

// The width over the height of the box, rounded down to a quarter, so a resized box reuses a few
// textures. to_fill_uv crops the rest from a texture a little taller than the box.
// @(private = "file") hides this procedure from other files.
@(private = "file")
to_crop :: proc(rect: [4]f32, focus_y: f32) -> image.Crop {
	height := rect.w - rect.y
	if height <= 0 do return {}

	// + 0.01 stops float noise from flooring a square, at 0.9999997, to 0.75 on some frames.
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

// A placeholder shows while a picture loads. Its gradient takes the picture's own colours, or two
// colours from the name when Apple sends none. Its symbol shows what the picture is.
Placeholder :: struct {
	top, bottom:  [4]f32,
	symbol:       string,
	symbol_color: [4]f32,
}

// Catalog artwork brings its colours, so the gradient previews the cover. Library artwork has
// none, so the name picks the hues. The same album then gets the same colours everywhere.
to_placeholder :: proc(
	artwork: apple.Artwork,
	seed: string,
	symbol := "music.note",
) -> Placeholder {
	if background, ok := parse_hex_color(artwork.bg_color); ok {
		ink, has_ink := parse_hex_color(artwork.text_color1)
		if !has_ink do ink = colors.text

		return {
			top = mix_color(background, ink, 0.18),
			bottom = mix_color(background, {0, 0, 0, 1}, 0.25),
			symbol = symbol,
			symbol_color = {ink.r, ink.g, ink.b, 0.5},
		}
	}

	// The FNV-1a hash of seed, with its offset basis and prime. transmute reads the bytes, no copy.
	hash := u32(2166136261)
	for character in transmute([]u8)seed do hash = (hash ~ u32(character)) * 16777619

	hue := f32(hash % 360)
	turn := 30 + f32((hash >> 9) % 70)

	return {
		top = to_color_from_hsl(hue, 0.34, 0.33),
		bottom = to_color_from_hsl(hue + turn, 0.3, 0.19),
		symbol = symbol,
		symbol_color = {1, 1, 1, 0.28},
	}
}

// A square of artwork over its placeholder. An empty source shows the placeholder only.
artwork_box :: proc(
	source: string,
	size_points: f32,
	radius_points: f32,
	placeholder: Placeholder,
) -> ^ui.Box {
	return artwork_rect_box(source, {size_points, size_points}, radius_points, placeholder)
}

artwork_rect_box :: proc(
	source: string,
	size_points: [2]f32,
	radius_points: f32,
	placeholder: Placeholder,
) -> ^ui.Box {
	box := ui.box(
		"",
		{
			width = ui.points(size_points.x),
			height = ui.points(size_points.y),
			corner_radius = radius_points,
			background = placeholder.top,
			end_background = placeholder.bottom,
			gradient = {0, 1},
		},
	)

	if source == "" && placeholder.symbol == "" do return box

	// The temp allocator keeps the paint until the next frame starts, after render draws the box.
	paint := new(Artwork_Paint, context.temp_allocator)
	paint^ = {
		source        = source,
		size_pixels   = int(ui.to_pixels(max(size_points.x, size_points.y))),
		symbol        = placeholder.symbol,
		// The symbol grows in steps of 4, so a tile that resizes with the panel reuses a few sizes.
		symbol_points = max(8, math.round(min(size_points.x, size_points.y) * 0.3 / 4) * 4),
		symbol_color  = placeholder.symbol_color,
		focus_y       = 0.5,
	}

	box.draw = draw_artwork
	box.data = paint

	return box
}
