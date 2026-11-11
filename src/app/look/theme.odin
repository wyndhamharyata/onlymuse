package look

import "core:math"
import "om:app/core"
import "thor:images"
import "thor:kit"
import "thor:platform"

colors := struct {
	sidebar, player, panel, youtube, drag_ghost, detail_card, detail_card_border: [4]f32,
} {
	sidebar            = kit.to_color(0xffffff08),
	player             = kit.to_color(0xffffff06),
	panel              = kit.to_color(0xffffff06),
	youtube            = kit.to_color(0xff4e45ff),
	drag_ghost         = kit.to_color(0x2c2c31f0),
	detail_card        = kit.to_color(0xffffff0a),
	detail_card_border = kit.to_color(0xffffff10),
}

// Translucent, so the blur behind the window shows.
WINDOW_COLOR :: 0x0e0e10bf

SIDEBAR_WIDTH_POINTS :: 228

PLAYER_HEIGHT_POINTS :: 70

TOOLBAR_HEIGHT_POINTS :: 44

PAGE_PADDING_POINTS :: 20

SHELF_TITLE_POINTS :: 17

PANEL_WIDTH_POINTS :: 320

MIN_WINDOW_WIDTH_POINTS :: 1000

MIN_WINDOW_HEIGHT_POINTS :: 600

LOADING_DELAY_SECONDS :: 0.3

LOADING_FADE_SECONDS :: 0.2

LOADING_DOT_SECONDS :: 0.4

LOADING_SWEEP_SECONDS :: 1.6

LOADING_BAR_WIDTH_POINTS :: 160

LOADING_SEGMENT_RATIO :: 0.3

LOADING_TEXT_POINTS :: 13

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
	color: images.Color
	has_color := false

	if artwork_source != "" do color, has_color = images.find_color(artwork_source)
	is_cover_vivid := has_color && color.vividness >= MIN_COVER_VIVIDNESS
	if is_cover_vivid do target = to_cover_accent(color.rgb)

	amount := 1 - math.exp(-ACCENT_RATE_PER_SECOND * min(frame_seconds, MAX_ACCENT_FRAME_SECONDS))
	kit.colors.primary += (target - kit.colors.primary) * amount
	difference := target.rgb - kit.colors.primary.rgb
	distance := abs(difference.r) + abs(difference.g) + abs(difference.b)

	if distance <= ACCENT_SETTLED_DISTANCE {
		kit.colors.primary = target
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

// A colour from hue in degrees, and saturation and lightness from 0 to 1, through kit's HSV.
to_color_from_hsl :: proc(hue, saturation, lightness: f32) -> [4]f32 {
	value := lightness + saturation * min(lightness, 1 - lightness)
	value_saturation := 2 * (1 - lightness / value) if value > 0 else 0

	return kit.to_color_from_hsv(hue, value_saturation, value)
}
