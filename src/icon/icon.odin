// AppKit draws each SF Symbol once per size into an atlas of masks, so any colour can fill it.
package icon

import "base:intrinsics"
import "core:math"
import NS "core:sys/darwin/Foundation"
import "om:mac"
import "om:render"
import MTL "vendor:darwin/Metal"

objc_send :: intrinsics.objc_send

@(objc_class = "NSImageSymbolConfiguration")
Symbol_Configuration :: struct {
	using _: NS.Object,
}

@(objc_class = "NSGraphicsContext")
Graphics_Context :: struct {
	using _: NS.Object,
}

@(private)
Entry :: struct {
	// x, y, width, height in atlas pixels. The width is 0 when the symbol does not exist.
	rect: [4]int,
}

@(private)
ATLAS_SIZE :: 1024
// NSFontWeightMedium.
@(private)
SYMBOL_WEIGHT :: 0.23
// NSCompositingOperationSourceOver.
@(private)
SOURCE_OVER :: 2

@(private)
state: struct {
	atlas:      ^MTL.Texture,
	entries:    map[[2]u64]Entry,
	pen:        [2]int,
	row_height: int,
	// rasterize sets this when a symbol finds no room. The atlas starts over on the next frame.
	is_full:    bool,
	// The atlas started over this frame. If it fills again, it holds less than one frame needs.
	// A request for more frames would only repeat that.
	is_fresh:   bool,
}

// Returns true when a symbol went undrawn for want of room, so another frame draws it.
is_redraw_needed :: proc() -> bool {
	return state.is_full && !state.is_fresh
}

// The app calls this once a frame, before it draws any symbol. It empties a full atlas. draw then puts
// each symbol in use back as the app asks for it. Emptying it mid-frame would change the queued draws.
begin_frame :: proc() {
	state.is_fresh = state.is_full
	if !state.is_full do return

	clear(&state.entries)
	state.pen = {}
	state.row_height = 0
	state.is_full = false
}

start :: proc() {
	state.atlas = render.make_texture({ATLAS_SIZE, ATLAS_SIZE}, .R8Unorm)
}

// Draws the symbol centred in rect, all in pixels.
draw :: proc(name: string, size_pixels: f32, rect, clip: [4]f32, color: [4]f32) {
	entry := find(name, size_pixels)

	if entry.rect.z == 0 do return

	width := f32(entry.rect.z)
	height := f32(entry.rect.w)
	left := math.round((rect.x + rect.z - width) / 2)
	top := math.round((rect.y + rect.w - height) / 2)
	uv :=
		[4]f32 {
			f32(entry.rect.x),
			f32(entry.rect.y),
			f32(entry.rect.x + entry.rect.z),
			f32(entry.rect.y + entry.rect.w),
		} /
		ATLAS_SIZE

	render.push(
		{
			rect = {left, top, left + width, top + height},
			uv = uv,
			color = color,
			clip = clip,
			kind = .Glyph,
		},
		state.atlas,
	)
}

@(private)
find :: proc(name: string, size_pixels: f32) -> Entry {
	key := [2]u64{u64(hash_text(name)), u64(size_pixels * 4)}

	if entry, ok := state.entries[key]; ok do return entry

	entry := rasterize(name, size_pixels)
	// find tries a symbol with no room again once the atlas starts over.
	if !state.is_full do state.entries[key] = entry

	return entry
}

@(private)
hash_text :: proc(text: string) -> u64 {
	value: u64 = 0xcbf29ce484222325
	for byte_value in transmute([]u8)text do value = (value ~ u64(byte_value)) * 0x100000001b3

	return value
}

@(private)
rasterize :: proc(name: string, size_pixels: f32) -> Entry {
	ns_name := NS.String.alloc()->initWithOdinString(name)
	defer ns_name->release()

	symbol := objc_send(
		^NS.Image,
		NS.Image,
		"imageWithSystemSymbolName:accessibilityDescription:",
		ns_name,
		rawptr(nil),
	)

	if symbol == nil do return {}

	configuration := objc_send(
		^Symbol_Configuration,
		Symbol_Configuration,
		"configurationWithPointSize:weight:",
		NS.Float(size_pixels),
		NS.Float(SYMBOL_WEIGHT),
	)
	image := objc_send(^NS.Image, symbol, "imageWithSymbolConfiguration:", configuration)

	size := objc_send(NS.Size, image, "size")
	width := int(math.ceil(f64(size.width))) + 2
	height := int(math.ceil(f64(size.height))) + 2
	rect, ok := allocate(width, height)

	if !ok {
		state.is_full = true
		return {}
	}

	pixels := make([]u8, width * height * 4, context.temp_allocator)
	space := mac.CGColorSpaceCreateDeviceRGB()
	defer mac.CGColorSpaceRelease(space)
	// kCGImageAlphaPremultipliedLast.
	bitmap_context := mac.CGBitmapContextCreate(
		raw_data(pixels),
		uint(width),
		uint(height),
		8,
		uint(width * 4),
		space,
		1,
	)
	defer mac.CGContextRelease(bitmap_context)

	graphics := objc_send(
		^Graphics_Context,
		Graphics_Context,
		"graphicsContextWithCGContext:flipped:",
		rawptr(bitmap_context),
		NS.BOOL(false),
	)

	objc_send(nil, Graphics_Context, "saveGraphicsState")
	objc_send(nil, Graphics_Context, "setCurrentContext:", graphics)
	target := NS.Rect{{1, 1}, size}
	objc_send(
		nil,
		image,
		"drawInRect:fromRect:operation:fraction:",
		target,
		NS.Rect{},
		NS.UInteger(SOURCE_OVER),
		NS.Float(1),
	)
	objc_send(nil, Graphics_Context, "restoreGraphicsState")

	// AppKit draws the symbol in black, so its alpha is the mask.
	mask := make([]u8, width * height, context.temp_allocator)
	for index in 0 ..< width * height do mask[index] = pixels[index * 4 + 3]

	render.upload_texture(state.atlas, rect, raw_data(mask), width)

	return Entry{rect}
}

// Shelf packing, as in the glyph atlas.
@(private)
allocate :: proc(width, height: int) -> ([4]int, bool) {
	if state.pen.x + width > ATLAS_SIZE {
		state.pen = {0, state.pen.y + state.row_height}
		state.row_height = 0
	}

	if state.pen.y + height > ATLAS_SIZE do return {}, false

	rect := [4]int{state.pen.x, state.pen.y, width, height}
	state.pen.x += width
	state.row_height = max(state.row_height, height)

	return rect, true
}
