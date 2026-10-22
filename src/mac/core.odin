// The C APIs of macOS the app calls, with only the procedures it uses.
package mac

foreign import core_foundation "system:CoreFoundation.framework"
foreign import core_graphics "system:CoreGraphics.framework"
foreign import core_text "system:CoreText.framework"
foreign import image_io "system:ImageIO.framework"

Type_Ref :: distinct rawptr
String_Ref :: Type_Ref
Dictionary_Ref :: Type_Ref
Array_Ref :: Type_Ref
Data_Ref :: Type_Ref
Url_Ref :: Type_Ref
Number_Ref :: Type_Ref
Attributed_String_Ref :: Type_Ref
Font_Ref :: Type_Ref
Line_Ref :: Type_Ref
Run_Ref :: Type_Ref
Typesetter_Ref :: Type_Ref
Context_Ref :: Type_Ref
Color_Space_Ref :: Type_Ref
Image_Ref :: Type_Ref
Image_Source_Ref :: Type_Ref

Index :: int
Glyph :: u16

Range :: struct {
	location: Index,
	length:   Index,
}

Point :: struct {
	x, y: f64,
}

Size :: struct {
	width, height: f64,
}

Rect :: struct {
	origin: Point,
	size:   Size,
}

STRING_ENCODING_UTF8 :: 0x08000100
NUMBER_INT32 :: 3

// CGImageAlphaInfo and CGBitmapInfo values.
IMAGE_ALPHA_NONE :: 0
IMAGE_ALPHA_PREMULTIPLIED_FIRST :: 2
BITMAP_BYTE_ORDER_32_LITTLE :: 2 << 12

Dictionary_Callbacks :: struct {
	version:     Index,
	retain:      rawptr,
	release:     rawptr,
	description: rawptr,
	equal:       rawptr,
	hash:        rawptr,
}

@(default_calling_convention = "c")
foreign core_foundation {
	kCFTypeDictionaryKeyCallBacks: Dictionary_Callbacks
	kCFTypeDictionaryValueCallBacks: Dictionary_Callbacks
	kCFBooleanTrue: Type_Ref

	CFRelease :: proc(object: Type_Ref) ---
	CFRetain :: proc(object: Type_Ref) -> Type_Ref ---
	CFHash :: proc(object: Type_Ref) -> uint ---
	CFStringCreateWithBytes :: proc(allocator: rawptr, bytes: [^]u8, count: Index, encoding: u32, is_external: b8) -> String_Ref ---
	CFStringGetLength :: proc(text: String_Ref) -> Index ---
	CFArrayGetCount :: proc(array: Array_Ref) -> Index ---
	CFArrayGetValueAtIndex :: proc(array: Array_Ref, index: Index) -> Type_Ref ---
	CFDictionaryCreate :: proc(allocator: rawptr, keys: [^]Type_Ref, values: [^]Type_Ref, count: Index, key_callbacks: ^Dictionary_Callbacks, value_callbacks: ^Dictionary_Callbacks) -> Dictionary_Ref ---
	CFDictionaryGetValue :: proc(dictionary: Dictionary_Ref, key: Type_Ref) -> Type_Ref ---
	CFAttributedStringCreate :: proc(allocator: rawptr, text: String_Ref, attributes: Dictionary_Ref) -> Attributed_String_Ref ---
	CFNumberCreate :: proc(allocator: rawptr, kind: Index, value: rawptr) -> Number_Ref ---
	CFURLCreateFromFileSystemRepresentation :: proc(allocator: rawptr, path: [^]u8, count: Index, is_directory: b8) -> Url_Ref ---
}

@(default_calling_convention = "c")
foreign core_graphics {
	CGColorSpaceCreateDeviceGray :: proc() -> Color_Space_Ref ---
	CGColorSpaceCreateDeviceRGB :: proc() -> Color_Space_Ref ---
	CGColorSpaceRelease :: proc(space: Color_Space_Ref) ---
	CGBitmapContextCreate :: proc(data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: Color_Space_Ref, bitmap_info: u32) -> Context_Ref ---
	CGContextRelease :: proc(graphics_context: Context_Ref) ---
	CGContextSetGrayFillColor :: proc(graphics_context: Context_Ref, gray, alpha: f64) ---
	CGContextSetAllowsFontSubpixelPositioning :: proc(graphics_context: Context_Ref, allows: b8) ---
	CGContextSetShouldSubpixelPositionFonts :: proc(graphics_context: Context_Ref, should: b8) ---
	CGContextSetAllowsFontSubpixelQuantization :: proc(graphics_context: Context_Ref, allows: b8) ---
	CGContextSetShouldSubpixelQuantizeFonts :: proc(graphics_context: Context_Ref, should: b8) ---
	CGContextDrawImage :: proc(graphics_context: Context_Ref, rect: Rect, image: Image_Ref) ---
	CGImageGetWidth :: proc(image: Image_Ref) -> uint ---
	CGImageGetHeight :: proc(image: Image_Ref) -> uint ---
	CGImageRelease :: proc(image: Image_Ref) ---
	// rect is in the image's pixels, from its top left.
	CGImageCreateWithImageInRect :: proc(image: Image_Ref, rect: Rect) -> Image_Ref ---
}

@(default_calling_convention = "c")
foreign core_text {
	kCTFontAttributeName: String_Ref

	CTFontGetAscent :: proc(font: Font_Ref) -> f64 ---
	CTFontGetDescent :: proc(font: Font_Ref) -> f64 ---
	CTFontGetLeading :: proc(font: Font_Ref) -> f64 ---
	CTFontGetBoundingRectsForGlyphs :: proc(font: Font_Ref, orientation: u32, glyphs: [^]Glyph, rects: [^]Rect, count: Index) -> Rect ---
	CTFontDrawGlyphs :: proc(font: Font_Ref, glyphs: [^]Glyph, positions: [^]Point, count: uint, graphics_context: Context_Ref) ---
	CTLineCreateWithAttributedString :: proc(text: Attributed_String_Ref) -> Line_Ref ---
	CTLineGetGlyphRuns :: proc(line: Line_Ref) -> Array_Ref ---
	CTLineGetTypographicBounds :: proc(line: Line_Ref, ascent, descent, leading: ^f64) -> f64 ---
	CTLineGetStringRange :: proc(line: Line_Ref) -> Range ---
	CTLineCreateTruncatedLine :: proc(line: Line_Ref, width: f64, truncation_type: u32, token: Line_Ref) -> Line_Ref ---
	CTRunGetGlyphCount :: proc(run: Run_Ref) -> Index ---
	CTRunGetGlyphs :: proc(run: Run_Ref, range: Range, buffer: [^]Glyph) ---
	CTRunGetPositions :: proc(run: Run_Ref, range: Range, buffer: [^]Point) ---
	CTRunGetStringIndices :: proc(run: Run_Ref, range: Range, buffer: [^]Index) ---
	CTRunGetAttributes :: proc(run: Run_Ref) -> Dictionary_Ref ---
	CTTypesetterCreateWithAttributedString :: proc(text: Attributed_String_Ref) -> Typesetter_Ref ---
	CTTypesetterSuggestLineBreak :: proc(typesetter: Typesetter_Ref, start: Index, width: f64) -> Index ---
	CTTypesetterCreateLine :: proc(typesetter: Typesetter_Ref, range: Range) -> Line_Ref ---
}

@(default_calling_convention = "c")
foreign image_io {
	kCGImageSourceCreateThumbnailFromImageAlways: String_Ref
	kCGImageSourceThumbnailMaxPixelSize: String_Ref
	kCGImageSourceCreateThumbnailWithTransform: String_Ref

	CGImageSourceCreateWithURL :: proc(url: Url_Ref, options: Dictionary_Ref) -> Image_Source_Ref ---
	CGImageSourceCreateThumbnailAtIndex :: proc(source: Image_Source_Ref, index: uint, options: Dictionary_Ref) -> Image_Ref ---
}

to_cf_string :: proc(text: string) -> String_Ref {
	return CFStringCreateWithBytes(nil, raw_data(text), len(text), STRING_ENCODING_UTF8, false)
}

make_dictionary :: proc(keys: []Type_Ref, values: []Type_Ref) -> Dictionary_Ref {
	return CFDictionaryCreate(
		nil,
		raw_data(keys),
		raw_data(values),
		len(keys),
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks,
	)
}
