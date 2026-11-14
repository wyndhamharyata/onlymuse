package look

import "core:math"
import "core:math/linalg"
import "om:apple"
import "thor:icon"
import "thor:images"
import "thor:kit"
import "thor:render"
import "thor:ui"
import MTL "vendor:darwin/Metal"

ARTWORK_STEP_PX :: 100

to_artwork_px :: proc(size: f32) -> int {
	px := int(ui.to_px(size))

	return (px + ARTWORK_STEP_PX - 1) / ARTWORK_STEP_PX * ARTWORK_STEP_PX
}

Artwork_Paint :: struct {
	source:       string,
	size_px:      int,
	symbol:       string,
	symbol_size:  f32,
	symbol_color: [4]f32,
	focus_y:      f32,
}

draw_artwork :: proc(box: ^ui.Box, rect_px, clip_px: [4]f32, opacity: f32) {
	paint := cast(^Artwork_Paint)box.data
	texture: ^MTL.Texture
	image_opacity: f32

	if paint.source != "" {
		texture, image_opacity = images.load_texture(
			paint.source,
			{f32(paint.size_px), f32(paint.size_px)},
			to_crop(rect_px, paint.focus_y),
		)
	}

	is_symbol_showing := image_opacity < 1 && paint.symbol != ""

	if is_symbol_showing {
		color := kit.with_opacity(paint.symbol_color, opacity * (1 - image_opacity))
		icon.draw(paint.symbol, ui.to_px(paint.symbol_size), rect_px, clip_px, color)
	}

	if texture == nil do return

	render.push(
		{
			rect = rect_px,
			uv = to_fill_uv(rect_px, texture, paint.focus_y),
			color = {1, 1, 1, opacity * image_opacity},
			corner_radius = box.style.corner_radius * ui.to_px(1),
			clip = clip_px,
			kind = .Image,
		},
		texture,
	)
}

@(private = "file")
to_crop :: proc(rect: [4]f32, focus_y: f32) -> images.Crop {
	height := rect.w - rect.y
	if height <= 0 do return {}

	// + 0.01 stops float noise from flooring a square, at 0.9999997, to 0.75 on some frames.
	return {math.floor((rect.z - rect.x) / height * 4 + 0.01) / 4, focus_y}
}

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

Placeholder :: struct {
	top, bottom:  [4]f32,
	symbol:       string,
	symbol_color: [4]f32,
}

to_placeholder :: proc(
	artwork: apple.Artwork,
	seed: string,
	symbol := "music.note",
) -> Placeholder {
	if bg, ok := kit.to_color_from_hex(artwork.bg_color); ok {
		text_color := kit.to_color_from_hex(artwork.text_color) or_else kit.colors.base_content

		return {
			top = linalg.lerp(bg, text_color, 0.18),
			bottom = linalg.lerp(bg, {0, 0, 0, 1}, 0.25),
			symbol = symbol,
			symbol_color = {text_color.r, text_color.g, text_color.b, 0.5},
		}
	}

	// The FNV-1a 32-bit offset basis and prime.
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

artwork_box :: proc(
	source: string,
	size: f32,
	radius: f32,
	placeholder: Placeholder,
) -> ^ui.Box {
	return artwork_rect_box(source, {size, size}, radius, placeholder)
}

artwork_rect_box :: proc(
	source: string,
	size: [2]f32,
	radius: f32,
	placeholder: Placeholder,
) -> ^ui.Box {
	box := ui.box(
		"",
		{
			width = ui.points(size.x),
			height = ui.points(size.y),
			corner_radius = radius,
			bg = placeholder.top,
			layers = {ui.Gradient{from = placeholder.top, to = placeholder.bottom}},
		},
	)

	if source == "" && placeholder.symbol == "" do return box

	paint := new(Artwork_Paint, context.temp_allocator)
	paint^ = {
		source       = source,
		size_px      = to_artwork_px(max(size.x, size.y)),
		symbol       = placeholder.symbol,
		symbol_size  = max(8, math.round(min(size.x, size.y) * 0.3 / 4) * 4),
		symbol_color = placeholder.symbol_color,
		focus_y      = 0.5,
	}

	box.draw = draw_artwork
	box.data = paint

	return box
}
