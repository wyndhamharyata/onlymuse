package font

import "base:intrinsics"
import "core:hash"
import "core:math"
import NS "core:sys/darwin/Foundation"
import "om:mac"
import "om:render"
import MTL "vendor:darwin/Metal"

objc_send :: intrinsics.objc_send

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
	ct_font:            mac.Font_Ref,
	size_pixels:        f32,
	ascent_pixels:      f32,
	descent_pixels:     f32,
	line_height_pixels: f32,
}

Placed_Glyph :: struct {
	font_index:  u16,
	glyph:       mac.Glyph,
	x_pixels:    f32,
	// A UTF-16 index, as CoreText counts.
	utf16_index: int,
}

Shaped_Line :: struct {
	glyphs:            []Placed_Glyph,
	width_pixels:      f32,
	baseline_y_pixels: f32,
	utf16_range:       [2]int,
}

Shaped_Text :: struct {
	lines:           []Shaped_Line,
	size_pixels:     [2]f32,
	last_used_frame: int,
}

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

system_font :: proc(weight: Weight, size_pixels: f32) -> Font {
	size_quarter_pixels := u32(size_pixels * 4)
	key := [2]u32{u32(weight), size_quarter_pixels}

	if font, ok := state.system_fonts[key]; ok do return font

	ns_font := objc_send(
		^NS_Font,
		NS_Font,
		"systemFontOfSize:weight:",
		NS.Float(size_pixels),
		NS.Float(weight_values[weight]),
	)

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

is_redraw_needed :: proc() -> bool {
	return state.is_atlas_reset
}

@(private)
free_shaped :: proc(shaped: ^Shaped_Text) {
	for line in shaped.lines do delete(line.glyphs)
	delete(shaped.lines)
	free(shaped)
}

Overflow :: enum {
	Wrap,
	Truncate,
}

// kCTLineTruncationEnd
@(private)
TRUNCATE_END :: 1

shape :: proc(
	text: string,
	font: Font,
	max_width_pixels: f32 = 0,
	overflow := Overflow.Wrap,
) -> ^Shaped_Text {
	key :=
		hash.fnv64a(transmute([]u8)text) ~
		(u64(mac.CFHash(mac.Type_Ref(font.ct_font))) * 31) ~
		(u64(max_width_pixels) << 40) ~
		(u64(overflow) << 62)

	if shaped, ok := state.shaped[key]; ok {
		shaped.last_used_frame = state.frame_index
		return shaped
	}

	shaped := new(Shaped_Text)
	shaped.last_used_frame = state.frame_index
	state.shaped[key] = shaped

	cf_text := mac.to_cf_string(text) if len(text) > 0 else nil

	if cf_text == nil {
		shaped.size_pixels = {0, font.line_height_pixels}
		return shaped
	}

	defer mac.CFRelease(cf_text)
	keys := []mac.Type_Ref{mac.Type_Ref(mac.kCTFontAttributeName)}
	values := []mac.Type_Ref{mac.Type_Ref(font.ct_font)}
	attributes := mac.make_dictionary(keys, values)
	defer mac.CFRelease(attributes)
	attributed := mac.CFAttributedStringCreate(nil, cf_text, attributes)
	defer mac.CFRelease(attributed)

	lines: [dynamic]Shaped_Line
	is_wrapped := max_width_pixels > 0 && overflow == .Wrap

	if !is_wrapped {
		ct_line := mac.CTLineCreateWithAttributedString(attributed)
		defer mac.CFRelease(ct_line)

		if max_width_pixels <= 0 {
			append(&lines, to_shaped_line(ct_line, font, 0))
		} else if line := make_truncated_line(ct_line, attributes, max_width_pixels); line != nil {
			append(&lines, to_shaped_line(line, font, 0))
			mac.CFRelease(line)
		}
	} else {
		typesetter := mac.CTTypesetterCreateWithAttributedString(attributed)
		defer mac.CFRelease(typesetter)
		utf16_count := mac.CFStringGetLength(cf_text)

		for start := 0; start < utf16_count; {
			count := mac.CTTypesetterSuggestLineBreak(typesetter, start, f64(max_width_pixels))
			if count <= 0 do break

			ct_line := mac.CTTypesetterCreateLine(typesetter, {start, count})
			top_y := f32(len(lines)) * font.line_height_pixels
			append(&lines, to_shaped_line(ct_line, font, top_y))
			mac.CFRelease(ct_line)
			start += count
		}
	}

	width: f32
	for line in lines do width = max(width, line.width_pixels)

	shaped.lines = lines[:]
	shaped.size_pixels = {width, f32(len(lines)) * font.line_height_pixels}

	return shaped
}

@(private)
make_truncated_line :: proc(
	ct_line: mac.Line_Ref,
	attributes: mac.Dictionary_Ref,
	max_width_pixels: f32,
) -> mac.Line_Ref {
	ellipsis := mac.to_cf_string("…")
	defer mac.CFRelease(ellipsis)
	ellipsis_attributed := mac.CFAttributedStringCreate(nil, ellipsis, attributes)
	defer mac.CFRelease(ellipsis_attributed)
	ellipsis_line := mac.CTLineCreateWithAttributedString(ellipsis_attributed)
	defer mac.CFRelease(ellipsis_line)

	return mac.CTLineCreateTruncatedLine(
		ct_line,
		f64(max_width_pixels),
		TRUNCATE_END,
		ellipsis_line,
	)
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
		run_font := mac.Font_Ref(
			mac.CFDictionaryGetValue(
				mac.CTRunGetAttributes(run),
				mac.Type_Ref(mac.kCTFontAttributeName),
			),
		)
		font_index := intern_font(run_font)

		ids := make([]mac.Glyph, count, context.temp_allocator)
		positions := make([]mac.Point, count, context.temp_allocator)
		indices := make([]mac.Index, count, context.temp_allocator)

		mac.CTRunGetGlyphs(run, {0, 0}, raw_data(ids))
		mac.CTRunGetPositions(run, {0, 0}, raw_data(positions))
		mac.CTRunGetStringIndices(run, {0, 0}, raw_data(indices))

		for index in 0 ..< count {
			append(
				&glyphs,
				Placed_Glyph{font_index, ids[index], f32(positions[index].x), indices[index]},
			)
		}
	}

	leading_pixels := font.line_height_pixels - font.ascent_pixels - font.descent_pixels
	baseline_y := top_y + math.round(leading_pixels / 2 + font.ascent_pixels)
	utf16_range := [2]int{string_range.location, string_range.location + string_range.length}

	return Shaped_Line{glyphs[:], width, baseline_y, utf16_range}
}
