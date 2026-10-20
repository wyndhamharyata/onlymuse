// Text shaped by CoreText and drawn from a glyph atlas.
package font

import "base:intrinsics"
import "core:hash"
import "core:math"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import "om:mac"
import "om:render"

msg_send :: intrinsics.objc_send

@(objc_class = "NSFont")
NS_Font :: struct {
	using _: NS.Object,
}

Weight :: enum {
	Regular,
	Medium,
	Semibold,
	Bold,
}

// NSFontWeight values, from NSFontDescriptor.h.
@(private)
weight_values := [Weight]f64 {
	.Regular  = 0,
	.Medium   = 0.23,
	.Semibold = 0.3,
	.Bold     = 0.4,
}

Font :: struct {
	ct_font:       mac.Font_Ref,
	size_pixels:   f32,
	ascent:        f32,
	descent:       f32,
	line_height:   f32,
}

Placed_Glyph :: struct {
	// Into state.fonts. CoreText picks another font for a character the first one lacks.
	font_index:  u16,
	glyph:       mac.Glyph,
	x:           f32,
	// UTF-16 index into the text, as CoreText counts.
	utf16_index: int,
}

Shaped_Line :: struct {
	glyphs:      []Placed_Glyph,
	width:       f32,
	// From the top of the text.
	baseline_y:  f32,
	utf16_range: [2]int,
}

Shaped_Text :: struct {
	lines:          []Shaped_Line,
	size:           [2]f32,
	last_used_frame: int,
}

@(private)
Atlas_Entry :: struct {
	// x, y, width, height in atlas pixels. Width 0 for a glyph with no ink, such as a space.
	rect:   [4]int,
	// From the pen position on the baseline to the top left of rect.
	offset: [2]f32,
}

@(private)
ATLAS_SIZE :: 4096
// The pen position is rounded to quarter pixels, so each glyph is drawn at most four times over.
@(private)
SUBPIXEL_STEPS :: 4
// A shaped text not drawn for this many frames is dropped.
@(private)
UNUSED_FRAME_COUNT :: 120

@(private)
state: struct {
	fonts:            [dynamic]mac.Font_Ref,
	font_indices:     map[uint]u16,
	system_fonts:     map[[2]u32]Font,
	shaped:           map[u64]^Shaped_Text,
	glyphs:           map[[3]u64]Atlas_Entry,
	atlas:            ^MTL.Texture,
	atlas_pen:        [2]int,
	atlas_row_height: int,
	frame_index:      int,
	is_atlas_reset:   bool,
}

start :: proc() {
	state.atlas = render.make_texture({ATLAS_SIZE, ATLAS_SIZE}, .R8Unorm)
}

// The system font, San Francisco, at a size in pixels.
system_font :: proc(weight: Weight, size_pixels: f32) -> Font {
	key := [2]u32{u32(weight), u32(size_pixels * 4)}

	if font, ok := state.system_fonts[key]; ok do return font

	ns_font := msg_send(^NS_Font, NS_Font, "systemFontOfSize:weight:", NS.Float(size_pixels), NS.Float(weight_values[weight]))
	// NSFont and CTFont are the same object.
	ct_font := mac.Font_Ref(mac.CFRetain(mac.Type_Ref(ns_font)))
	ascent := f32(mac.CTFontGetAscent(ct_font))
	descent := f32(mac.CTFontGetDescent(ct_font))
	leading := f32(mac.CTFontGetLeading(ct_font))
	font := Font{ct_font, size_pixels, ascent, descent, math.ceil(ascent + descent + leading)}
	state.system_fonts[key] = font

	return font
}

@(private)
intern_font :: proc(ct_font: mac.Font_Ref) -> u16 {
	key := mac.CFHash(mac.Type_Ref(ct_font))

	if index, ok := state.font_indices[key]; ok do return index

	mac.CFRetain(mac.Type_Ref(ct_font))
	index := u16(len(state.fonts))
	append(&state.fonts, ct_font)
	state.font_indices[key] = index

	return index
}

// Called once a frame, before any text is shaped or drawn.
begin_frame :: proc() {
	state.frame_index += 1
	state.is_atlas_reset = false

	if state.frame_index % UNUSED_FRAME_COUNT != 0 do return

	for key, shaped in state.shaped {
		if state.frame_index - shaped.last_used_frame < UNUSED_FRAME_COUNT do continue

		free_shaped(shaped)
		delete_key(&state.shaped, key)
	}
}

// True when the atlas filled and started over during this frame, so glyphs drawn earlier in it are wrong.
is_redraw_needed :: proc() -> bool {
	return state.is_atlas_reset
}

@(private)
free_shaped :: proc(shaped: ^Shaped_Text) {
	for line in shaped.lines do delete(line.glyphs)
	delete(shaped.lines)
	free(shaped)
}

// Shapes text once and keeps it while it is drawn. max_width_pixels 0 keeps it on one line.
shape :: proc(text: string, font: Font, max_width_pixels: f32 = 0) -> ^Shaped_Text {
	key := hash.fnv64a(transmute([]u8)text) ~ (u64(mac.CFHash(mac.Type_Ref(font.ct_font))) * 31) ~ (u64(max_width_pixels) << 40)

	if shaped, ok := state.shaped[key]; ok {
		shaped.last_used_frame = state.frame_index
		return shaped
	}

	shaped := new(Shaped_Text)
	shaped.last_used_frame = state.frame_index
	state.shaped[key] = shaped

	if len(text) == 0 {
		shaped.size = {0, font.line_height}
		return shaped
	}

	cf_text := mac.to_cf_string(text)
	defer mac.CFRelease(cf_text)
	keys := []mac.Type_Ref{mac.Type_Ref(mac.kCTFontAttributeName)}
	values := []mac.Type_Ref{mac.Type_Ref(font.ct_font)}
	attributes := mac.make_dictionary(keys, values)
	defer mac.CFRelease(attributes)
	attributed := mac.CFAttributedStringCreate(nil, cf_text, attributes)
	defer mac.CFRelease(attributed)

	lines: [dynamic]Shaped_Line

	if max_width_pixels <= 0 {
		ct_line := mac.CTLineCreateWithAttributedString(attributed)
		append(&lines, to_shaped_line(ct_line, font, 0))
		mac.CFRelease(ct_line)
	} else {
		typesetter := mac.CTTypesetterCreateWithAttributedString(attributed)
		defer mac.CFRelease(typesetter)
		utf16_count := mac.CFStringGetLength(cf_text)

		for start := 0; start < utf16_count; {
			count := mac.CTTypesetterSuggestLineBreak(typesetter, start, f64(max_width_pixels))
			if count <= 0 do break

			ct_line := mac.CTTypesetterCreateLine(typesetter, {start, count})
			append(&lines, to_shaped_line(ct_line, font, f32(len(lines)) * font.line_height))
			mac.CFRelease(ct_line)
			start += count
		}
	}

	width: f32
	for line in lines do width = max(width, line.width)

	shaped.lines = lines[:]
	shaped.size = {width, f32(len(lines)) * font.line_height}

	return shaped
}

@(private)
to_shaped_line :: proc(ct_line: mac.Line_Ref, font: Font, top_y: f32) -> Shaped_Line {
	ascent, descent, leading: f64
	width := f32(mac.CTLineGetTypographicBounds(ct_line, &ascent, &descent, &leading))
	string_range := mac.CTLineGetStringRange(ct_line)
	runs := mac.CTLineGetGlyphRuns(ct_line)
	glyphs: [dynamic]Placed_Glyph

	for run_index in 0 ..< mac.CFArrayGetCount(runs) {
		run := mac.Run_Ref(mac.CFArrayGetValueAtIndex(runs, run_index))
		count := mac.CTRunGetGlyphCount(run)
		run_font := mac.Font_Ref(mac.CFDictionaryGetValue(mac.CTRunGetAttributes(run), mac.Type_Ref(mac.kCTFontAttributeName)))
		font_index := intern_font(run_font)

		ids := make([]mac.Glyph, count, context.temp_allocator)
		positions := make([]mac.Point, count, context.temp_allocator)
		indices := make([]mac.Index, count, context.temp_allocator)
		mac.CTRunGetGlyphs(run, {0, 0}, raw_data(ids))
		mac.CTRunGetPositions(run, {0, 0}, raw_data(positions))
		mac.CTRunGetStringIndices(run, {0, 0}, raw_data(indices))

		for index in 0 ..< count {
			append(&glyphs, Placed_Glyph{font_index, ids[index], f32(positions[index].x), indices[index]})
		}
	}

	baseline_y := top_y + math.round((font.line_height - font.ascent - font.descent) / 2 + font.ascent)
	utf16_range := [2]int{string_range.location, string_range.location + string_range.length}

	return Shaped_Line{glyphs[:], width, baseline_y, utf16_range}
}

// Draws every glyph. color_of picks a colour per glyph, such as the sung words of a lyric line.
draw :: proc(shaped: ^Shaped_Text, origin_pixels: [2]f32, color: [4]f32, clip: [4]f32, color_of: proc(utf16_index: int, data: rawptr) -> [4]f32 = nil, data: rawptr = nil) {
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

			uv := [4]f32{f32(entry.rect.x), f32(entry.rect.y), f32(entry.rect.x + entry.rect.z), f32(entry.rect.y + entry.rect.w)} / ATLAS_SIZE
			glyph_color := color_of(glyph.utf16_index, data) if color_of != nil else color
			render.push({rect = rect, uv = uv, color = glyph_color, clip = clip, kind = .Glyph}, state.atlas)
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

	// One pixel of room on each side for antialiasing, and one more on the right for the subpixel shift.
	left := int(math.floor(bounds.origin.x)) - 1
	bottom := int(math.floor(bounds.origin.y)) - 1
	width := int(math.ceil(bounds.origin.x + bounds.size.width)) - left + 2
	height := int(math.ceil(bounds.origin.y + bounds.size.height)) - bottom + 1

	rect, ok := allocate(width, height)
	if !ok do return {}

	pixels := make([]u8, width * height, context.temp_allocator)
	gray := mac.CGColorSpaceCreateDeviceGray()
	defer mac.CGColorSpaceRelease(gray)
	ctx := mac.CGBitmapContextCreate(raw_data(pixels), uint(width), uint(height), 8, uint(width), gray, mac.IMAGE_ALPHA_NONE)
	defer mac.CGContextRelease(ctx)

	mac.CGContextSetAllowsFontSubpixelPositioning(ctx, true)
	mac.CGContextSetShouldSubpixelPositionFonts(ctx, true)
	mac.CGContextSetAllowsFontSubpixelQuantization(ctx, false)
	mac.CGContextSetShouldSubpixelQuantizeFonts(ctx, false)
	mac.CGContextSetGrayFillColor(ctx, 1, 1)

	position := mac.Point{f64(-left) + f64(subpixel) / SUBPIXEL_STEPS, f64(-bottom)}
	mac.CTFontDrawGlyphs(ct_font, &glyph, &position, 1, ctx)
	render.upload_texture(state.atlas, rect, raw_data(pixels), width)

	// CoreGraphics counts y up from the bottom of the bitmap. The screen counts down from the top.
	return Atlas_Entry{rect, {f32(left), -f32(height + bottom)}}
}

// Shelf packing: glyphs fill a row left to right, and a new row starts below the tallest one.
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
