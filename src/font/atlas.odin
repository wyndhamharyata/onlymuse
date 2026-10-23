package font

import "base:intrinsics"
import "core:math"
import "om:mac"
import "om:render"

@(private)
Atlas_Entry :: struct {
	region: [4]int,
	offset: [2]f32,
}

@(private)
ATLAS_SIZE :: 4096

@(private)
SUBPIXEL_STEPS :: 4

Color_Proc :: #type proc(utf16_index: int, data: rawptr) -> [4]f32

draw :: proc(
	shaped: ^Shaped_Text,
	origin_pixels: [2]f32,
	color: [4]f32,
	clip_pixels: [4]f32,
	color_of: Color_Proc,
	data: rawptr,
	opacity: f32,
) {
	for line in shaped.lines {
		baseline_y := math.round(origin_pixels.y + line.baseline_y_pixels)
		is_line_outside :=
			baseline_y - shaped.size_pixels.y > clip_pixels.w ||
			baseline_y + shaped.size_pixels.y < clip_pixels.y

		if is_line_outside do continue

		for glyph in line.glyphs {
			pen_x := origin_pixels.x + glyph.x_pixels
			whole_x := math.floor(pen_x)
			subpixel := int((pen_x - whole_x) * SUBPIXEL_STEPS)
			entry := find_glyph(glyph.font_index, glyph.glyph, subpixel)
			region := entry.region

			if region.z == 0 do continue

			left := whole_x + entry.offset.x
			top := baseline_y + entry.offset.y
			rect := [4]f32{left, top, left + f32(region.z), top + f32(region.w)}
			is_glyph_outside := rect.z < clip_pixels.x || rect.x > clip_pixels.z

			if is_glyph_outside do continue

			uv :=
				[4]f32 {
					f32(region.x),
					f32(region.y),
					f32(region.x + region.z),
					f32(region.y + region.w),
				} /
				ATLAS_SIZE
			glyph_color := color_of(glyph.utf16_index, data) if color_of != nil else color
			glyph_color.a *= opacity

			render.push(
				{rect = rect, uv = uv, color = glyph_color, clip = clip_pixels, kind = .Glyph},
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

	has_ink := bounds.size.width > 0 && bounds.size.height > 0

	if !has_ink do return {}

	left := int(math.floor(bounds.origin.x)) - 1
	bottom := int(math.floor(bounds.origin.y)) - 1
	width := int(math.ceil(bounds.origin.x + bounds.size.width)) - left + 2
	height := int(math.ceil(bounds.origin.y + bounds.size.height)) - bottom + 1

	region, ok := allocate(width, height)

	if !ok do return {}

	BITS_PER_COMPONENT :: 8
	pixels := make([]u8, width * height, context.temp_allocator)
	gray := mac.CGColorSpaceCreateDeviceGray()
	defer mac.CGColorSpaceRelease(gray)
	bitmap_context := mac.CGBitmapContextCreate(
		raw_data(pixels),
		uint(width),
		uint(height),
		BITS_PER_COMPONENT,
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
	render.upload_texture(state.atlas, region, raw_data(pixels), width)

	// CoreGraphics counts y up from the bottom of the bitmap. The screen counts down from the top.
	return Atlas_Entry{region, {f32(left), -f32(height + bottom)}}
}

@(private)
allocate :: proc(width, height: int) -> ([4]int, bool) {
	if width > ATLAS_SIZE || height > ATLAS_SIZE do return {}, false

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

	region := [4]int{state.atlas_pen.x, state.atlas_pen.y, width, height}
	state.atlas_pen.x += width
	state.atlas_row_height = max(state.atlas_row_height, height)

	return region, true
}
