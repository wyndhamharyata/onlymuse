package app

import "core:math"
import "core:strconv"

to_color :: proc "contextless" (hex: u32) -> [4]f32 {
	return {f32((hex >> 24) & 0xff) / 255, f32((hex >> 16) & 0xff) / 255, f32((hex >> 8) & 0xff) / 255, f32(hex & 0xff) / 255}
}

// "#F7821B", as the helper sends the system accent.
to_color_from_hex :: proc(hex: string) -> [4]f32 {
	if len(hex) != 7 || hex[0] != '#' do return DEFAULT_ACCENT

	value, ok := strconv.parse_u64_of_base(hex[1:], 16)
	if !ok do return DEFAULT_ACCENT

	return to_color(u32(value << 8) | 0xff)
}

// The colours of the gpuix app's src/theme.ts. The window blurs what is behind it and tints it at 85%.
colors := struct {
	window, sidebar, player, panel, ink, line, card, hover, selected, field, text, dim, faint, track: [4]f32,
} {
	window   = to_color(0x1b1b1ed9),
	sidebar  = to_color(0xffffff08),
	player   = to_color(0xffffff06),
	panel    = to_color(0xffffff06),
	// Solid, for marks drawn on white, such as the play icon.
	ink      = to_color(0x1b1b1eff),
	line     = to_color(0x2e2e33ff),
	card     = to_color(0x2a2a2fff),
	hover    = to_color(0xffffff12),
	selected = to_color(0xffffff1a),
	field    = to_color(0xffffff12),
	text     = to_color(0xf2f2f4ff),
	dim      = to_color(0xacacb4ff),
	faint    = to_color(0x8a8a93ff),
	track    = to_color(0x3a3a40ff),
}

DEFAULT_ACCENT :: [4]f32{0x0a / 255.0, 0x84 / 255.0, 1, 1}
// 0x2e of 0xff, about 18 percent, as the selected rows in the design.
ACCENT_TINT_ALPHA :: 0x2e / 255.0

to_accent_tint :: proc(accent: [4]f32) -> [4]f32 {
	return {accent.r, accent.g, accent.b, ACCENT_TINT_ALPHA}
}

SIDEBAR_WIDTH_POINTS :: 228
PLAYER_HEIGHT_POINTS :: 70
// As tall as the traffic lights' strip.
TOOLBAR_HEIGHT_POINTS :: 44
PAGE_PADDING_POINTS :: 20
PANEL_WIDTH_POINTS :: 320
// The sidebar, the panel and a page two tiles wide, with the player bar's three parts unsqueezed.
MIN_WINDOW_WIDTH_POINTS :: 1000
MIN_WINDOW_HEIGHT_POINTS :: 600

// "2a2a2f", as Apple sends artwork colours.
parse_hex_color :: proc(hex: string) -> ([4]f32, bool) {
	if len(hex) != 6 do return {}, false

	value, ok := strconv.parse_u64_of_base(hex, 16)
	if !ok do return {}, false

	return to_color(u32(value << 8) | 0xff), true
}

mix_color :: proc(from, to: [4]f32, amount: f32) -> [4]f32 {
	return from + (to - from) * amount
}

// Hue in degrees, saturation and lightness from 0 to 1.
to_color_from_hsl :: proc(hue, saturation, lightness: f32) -> [4]f32 {
	chroma := (1 - abs(2 * lightness - 1)) * saturation
	sector := math.mod(hue, 360) / 60
	second := chroma * (1 - abs(math.mod(sector, 2) - 1))
	rgb: [3]f32

	switch int(sector) {
	case 0: rgb = {chroma, second, 0}
	case 1: rgb = {second, chroma, 0}
	case 2: rgb = {0, chroma, second}
	case 3: rgb = {0, second, chroma}
	case 4: rgb = {second, 0, chroma}
	case: rgb = {chroma, 0, second}
	}

	base := lightness - chroma / 2

	return {rgb.r + base, rgb.g + base, rgb.b + base, 1}
}
