package kit

import "core:math"
import "core:strconv"
import "om:app/core"
import "om:image"
import "om:platform"

to_color :: proc "contextless" (hex: u32) -> [4]f32 {
	return {
		f32((hex >> 24) & 0xff) / 255,
		f32((hex >> 16) & 0xff) / 255,
		f32((hex >> 8) & 0xff) / 255,
		f32(hex & 0xff) / 255,
	}
}

to_color_from_hex :: proc(hex: string) -> [4]f32 {
	if len(hex) != 7 || hex[0] != '#' do return DEFAULT_ACCENT

	return to_color_from_hex_digits(hex[1:]) or_else DEFAULT_ACCENT
}

colors := struct {
	window, sidebar, player, panel, ink, line, card, hover, selected, field, text, dim, faint, track, youtube: [4]f32,
	white, popover, toast, drag_ghost, popover_border:                                                         [4]f32,
	detail_card, detail_card_border:                                                                           [4]f32,
} {
	window             = to_color(0x0e0e10bf),
	sidebar            = to_color(0xffffff08),
	player             = to_color(0xffffff06),
	panel              = to_color(0xffffff06),
	ink                = to_color(0x1b1b1eff),
	line               = to_color(0x2e2e33ff),
	card               = to_color(0x2a2a2fff),
	hover              = to_color(0xffffff12),
	selected           = to_color(0xffffff1a),
	field              = to_color(0xffffff12),
	text               = to_color(0xf2f2f4ff),
	dim                = to_color(0xacacb4ff),
	faint              = to_color(0x8a8a93ff),
	track              = to_color(0x3a3a40ff),
	youtube            = to_color(0xff4e45ff),
	white              = to_color(0xffffffff),
	popover            = to_color(0x2c2c31f5),
	toast              = to_color(0x2c2c31ff),
	drag_ghost         = to_color(0x2c2c31f0),
	popover_border     = to_color(0xffffff1c),
	detail_card        = to_color(0xffffff0a),
	detail_card_border = to_color(0xffffff10),
}

DEFAULT_ACCENT :: [4]f32{0x0a / 255.0, 0x84 / 255.0, 1, 1}

ACCENT_TINT_ALPHA :: 0x2e / 255.0

to_faded :: proc(color: [4]f32, opacity: f32) -> [4]f32 {
	return {color.r, color.g, color.b, color.a * opacity}
}

to_accent_tint :: proc(accent: [4]f32) -> [4]f32 {
	return {accent.r, accent.g, accent.b, ACCENT_TINT_ALPHA}
}

SIDEBAR_WIDTH_POINTS :: 228

PLAYER_HEIGHT_POINTS :: 70

TOOLBAR_HEIGHT_POINTS :: 44

PAGE_PADDING_POINTS :: 20

SHELF_TITLE_POINTS :: 17

SMALL_TEXT_POINTS :: 12.5

BUTTON_HEIGHT_POINTS :: 32

ICON_BUTTON_PADDING_POINTS :: 4

PANEL_WIDTH_POINTS :: 320

MIN_WINDOW_WIDTH_POINTS :: 1000

MIN_WINDOW_HEIGHT_POINTS :: 600

to_color_from_hex_digits :: proc(hex: string) -> ([4]f32, bool) {
	if len(hex) != 6 do return {}, false

	value, ok := strconv.parse_u64_of_base(hex, 16)
	if !ok do return {}, false

	return to_color(u32(value << 8) | 0xff), true
}

mix_color :: proc(from, to: [4]f32, amount: f32) -> [4]f32 {
	return from + (to - from) * amount
}

to_color_from_hsl :: proc(hue, saturation, lightness: f32) -> [4]f32 {
	chroma := (1 - abs(2 * lightness - 1)) * saturation
	sector := math.mod(hue, 360) / 60
	second := chroma * (1 - abs(math.mod(sector, 2) - 1))
	rgb: [3]f32

	switch int(sector) {
	case 0:
		rgb = {chroma, second, 0}
	case 1:
		rgb = {second, chroma, 0}
	case 2:
		rgb = {0, chroma, second}
	case 3:
		rgb = {0, second, chroma}
	case 4:
		rgb = {second, 0, chroma}
	case:
		rgb = {chroma, 0, second}
	}

	base := lightness - chroma / 2

	return {rgb.r + base, rgb.g + base, rgb.b + base, 1}
}

MIN_COVER_VIVIDNESS :: 0.015

MIN_COVER_ACCENT_SATURATION :: 0.55

MAX_COVER_ACCENT_SATURATION :: 0.9

MIN_COVER_ACCENT_LIGHTNESS :: 0.5

MAX_COVER_ACCENT_LIGHTNESS :: 0.65

MIN_ACCENT_LUMINANCE :: 0.24

MAX_RAISED_ACCENT_LIGHTNESS :: 0.8

ACCENT_RATE_PER_SECOND :: 8

MAX_ACCENT_FRAME_SECONDS :: 0.1

ACCENT_SETTLED_DISTANCE :: 0.003

set_accent :: proc(frame_seconds: f32, artwork_source: string) {
	target := core.app.system_accent
	color: image.Color
	has_color := false

	if artwork_source != "" do color, has_color = image.find_color(artwork_source)
	is_cover_vivid := has_color && color.vividness >= MIN_COVER_VIVIDNESS
	if is_cover_vivid do target = to_cover_accent(color.rgb)

	amount := 1 - math.exp(-ACCENT_RATE_PER_SECOND * min(frame_seconds, MAX_ACCENT_FRAME_SECONDS))
	core.app.accent += (target - core.app.accent) * amount
	difference := target.rgb - core.app.accent.rgb
	distance := abs(difference.r) + abs(difference.g) + abs(difference.b)

	if distance <= ACCENT_SETTLED_DISTANCE {
		core.app.accent = target
		return
	}

	platform.request_frame()
}

to_cover_accent :: proc(rgb: [3]f32) -> [4]f32 {
	hue, saturation, lightness := to_hsl(rgb)
	saturation = clamp(saturation, MIN_COVER_ACCENT_SATURATION, MAX_COVER_ACCENT_SATURATION)
	lightness = clamp(lightness, MIN_COVER_ACCENT_LIGHTNESS, MAX_COVER_ACCENT_LIGHTNESS)
	color := to_rgb_from_hsl(hue, saturation, lightness)

	for to_luminance(color) < MIN_ACCENT_LUMINANCE && lightness < MAX_RAISED_ACCENT_LIGHTNESS {
		lightness += 0.02
		color = to_rgb_from_hsl(hue, saturation, lightness)
	}

	return {color.r, color.g, color.b, 1}
}

@(private = "file")
to_luminance :: proc(rgb: [3]f32) -> f32 {
	return 0.2126 * to_linear(rgb.r) + 0.7152 * to_linear(rgb.g) + 0.0722 * to_linear(rgb.b)
}

// One sRGB channel as linear light, as WCAG gives it.
@(private = "file")
to_linear :: proc(value: f32) -> f32 {
	return value / 12.92 if value <= 0.04045 else math.pow((value + 0.055) / 1.055, 2.4)
}

@(private = "file")
to_hsl :: proc(rgb: [3]f32) -> (hue, saturation, lightness: f32) {
	brightest := max(rgb.r, rgb.g, rgb.b)
	darkest := min(rgb.r, rgb.g, rgb.b)
	lightness = (brightest + darkest) / 2
	spread := brightest - darkest
	if spread <= 0 do return 0, 0, lightness

	saturation = spread / (1 - abs(2 * lightness - 1))

	switch brightest {
	case rgb.r:
		hue = math.mod((rgb.g - rgb.b) / spread, 6)
	case rgb.g:
		hue = (rgb.b - rgb.r) / spread + 2
	case:
		hue = (rgb.r - rgb.g) / spread + 4
	}

	hue /= 6
	if hue < 0 do hue += 1

	return
}

@(private = "file")
to_rgb_from_hsl :: proc(hue, saturation, lightness: f32) -> [3]f32 {
	return to_color_from_hsl(hue * 360, saturation, lightness).rgb
}
