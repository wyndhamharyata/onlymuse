package look

import "core:math/linalg"
import "om:apple"
import "thor:kit"
import "thor:ui"

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

// A song's, album's or card's artwork, cropped to fill size points, over its placeholder until it loads.
artwork_box :: proc(
	source, label: string,
	size: f32,
	radius: f32,
	placeholder: Placeholder,
) -> ^ui.Box {
	return artwork_rect_box(source, label, {size, size}, radius, placeholder)
}

artwork_rect_box :: proc(
	source, label: string,
	size: [2]f32,
	radius: f32,
	placeholder: Placeholder,
	focus_y: f32 = 0.5,
) -> ^ui.Box {
	style := ui.Style {
		width         = ui.points(size.x),
		height        = ui.points(size.y),
		corner_radius = radius,
		bg            = placeholder.top,
		layers        = {ui.Gradient{from = placeholder.top, to = placeholder.bottom}},
	}

	return kit.image(
		source,
		label,
		style,
		placeholder_icon = placeholder.symbol,
		placeholder_color = placeholder.symbol_color,
		focus_y = focus_y,
	).box
}
