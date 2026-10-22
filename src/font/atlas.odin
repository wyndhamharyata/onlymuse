package font

import "base:intrinsics"
import "core:math"
import "om:mac"
import "om:render"

@(private)
Atlas_Entry :: struct {
	// x, y, width, height in atlas pixels. The width is 0 for a glyph with no ink, such as a space.
	rect:   [4]int,
	// From the pen position on the baseline to the top left of rect.
	offset: [2]f32,
}

@(private)
ATLAS_SIZE :: 4096

// draw rounds the pen position to quarter pixels, so the atlas holds each glyph at most four times.
@(private)
SUBPIXEL_STEPS :: 4

Color_Proc :: #type proc(utf16_index: int, data: rawptr) -> [4]f32

// Draws every glyph. color_of picks a colour per glyph, such as the sung words of a lyric line. opacity scales either.
draw :: proc(
	shaped: ^Shaped_Text,
	origin_pixels: [2]f32,
	color: [4]f32,
	clip: [4]f32,
	color_of: Color_Proc = nil,
	data: rawptr = nil,
	opacity: f32 = 1,
) {
	for line in shaped.lines {
		baseline_y := math.round(origin_pixels.y + line.baseline_y)

		// The whole line is out of the clip.
		if baseline_y - shaped.size.y > clip.w || baseline_y + shaped.size.y < clip.y do continue

		for glyph in line.glyphs {
			pen_x := origin_pixels.x + glyph.x
			whole_x := math.floor(pen_x)
			subpixel := int((pen_x - whole_x) * SUBPIXEL_STEPS)
			entry := find_glyph(glyph.font_index, glyph.glyph, subpixel)

			if entry.rect.z == 0 do continue

			left := whole_x + entry.offset.x
			top := baseline_y + entry.offset.y
			rect := [4]f32{left, top, left + f32(entry.rect.z), top + f32(entry.rect.w)}

			if rect.z < clip.x || rect.x > clip.z do continue

			uv :=
				[4]f32 {
					f32(entry.rect.x),
					f32(entry.rect.y),
					f32(entry.rect.x + entry.rect.z),
					f32(entry.rect.y + entry.rect.w),
				} /
				ATLAS_SIZE
			glyph_color := color_of(glyph.utf16_index, data) if color_of != nil else color
			glyph_color.a *= opacity

			render.push(
				{rect = rect, uv = uv, color = glyph_color, clip = clip, kind = .Glyph},
				state.atlas,
			)
		}
	}
}

@(private)
find_glyph :: proc(font_index: u16, glyph: mac.Glyph, subpixel: int) -> Atlas_Entry {
	key := [3]u64{u64(font_index), u64(glyph), u64(subpixel)}

	if entry, ok := state.glyphs[key]; ok do return entry

	entry := rasterize(state.fonts[font_index], glyph, subpixel)
	state.glyphs[key] = entry

	return entry
}

@(private)
rasterize :: proc(ct_font: mac.Font_Ref, glyph: mac.Glyph, subpixel: int) -> Atlas_Entry {
	glyph := glyph
	bounds: mac.Rect

	mac.CTFontGetBoundingRectsForGlyphs(ct_font, 0, &glyph, &bounds, 1)

	if bounds.size.width <= 0 || bounds.size.height <= 0 do return {}

	// Each side gets one pixel of room for antialiasing. The right gets one more for the subpixel shift.
	left := int(math.floor(bounds.origin.x)) - 1
	bottom := int(math.floor(bounds.origin.y)) - 1
	width := int(math.ceil(bounds.origin.x + bounds.size.width)) - left + 2
	height := int(math.ceil(bounds.origin.y + bounds.size.height)) - bottom + 1

	rect, ok := allocate(width, height)

	if !ok do return {}

	pixels := make([]u8, width * height, context.temp_allocator)
	gray := mac.CGColorSpaceCreateDeviceGray()
	defer mac.CGColorSpaceRelease(gray)
	bitmap_context := mac.CGBitmapContextCreate(
		raw_data(pixels),
		uint(width),
		uint(height),
		8,
		uint(width),
		gray,
		mac.IMAGE_ALPHA_NONE,
	)
	defer mac.CGContextRelease(bitmap_context)

	mac.CGContextSetAllowsFontSubpixelPositioning(bitmap_context, true)
	mac.CGContextSetShouldSubpixelPositionFonts(bitmap_context, true)
	mac.CGContextSetAllowsFontSubpixelQuantization(bitmap_context, false)
	mac.CGContextSetShouldSubpixelQuantizeFonts(bitmap_context, false)
	mac.CGContextSetGrayFillColor(bitmap_context, 1, 1)

	position := mac.Point{f64(-left) + f64(subpixel) / SUBPIXEL_STEPS, f64(-bottom)}

	mac.CTFontDrawGlyphs(ct_font, &glyph, &position, 1, bitmap_context)
	render.upload_texture(state.atlas, rect, raw_data(pixels), width)

	// CoreGraphics counts y up from the bottom of the bitmap. The screen counts down from the top.
	return Atlas_Entry{rect, {f32(left), -f32(height + bottom)}}
}

// This is shelf packing. Glyphs fill a row from left to right. A new row starts below the tallest one.
@(private)
allocate :: proc(width, height: int) -> ([4]int, bool) {
	if state.atlas_pen.x + width > ATLAS_SIZE {
		state.atlas_pen = {0, state.atlas_pen.y + state.atlas_row_height}
		state.atlas_row_height = 0
	}

	if state.atlas_pen.y + height > ATLAS_SIZE {
		clear(&state.glyphs)
		state.atlas_pen = {0, 0}
		state.atlas_row_height = 0
		state.is_atlas_reset = true
	}

	if width > ATLAS_SIZE || height > ATLAS_SIZE do return {}, false

	rect := [4]int{state.atlas_pen.x, state.atlas_pen.y, width, height}
	state.atlas_pen.x += width
	state.atlas_row_height = max(state.atlas_row_height, height)

	return rect, true
}
