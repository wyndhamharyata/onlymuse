package icon

import "base:intrinsics"
import "core:hash"
import "core:math"
import NS "core:sys/darwin/Foundation"
import "om:mac"
import "om:render"
import MTL "vendor:darwin/Metal"

@(private)
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
ATLAS_SIZE_PIXELS :: 1024
@(private)
SIZE_STEPS_PER_PIXEL :: 4
@(private)
PADDING_PIXELS :: 1
@(private)
BYTES_PER_PIXEL :: 4
@(private)
BITS_PER_CHANNEL :: 8
// kCGImageAlphaPremultipliedLast, from CoreGraphics' CGImageAlphaInfo.
@(private)
ALPHA_PREMULTIPLIED_LAST :: 1
// NSFontWeightMedium.
@(private)
SYMBOL_WEIGHT :: 0.23
@(private)
SOURCE_OVER :: 2

@(private)
state: struct {
	atlas:      ^MTL.Texture,
	regions:    map[[2]u64][4]int,
	pen:        [2]int,
	row_height: int,
	is_full:    bool,
	is_fresh:   bool,
}

is_redraw_needed :: proc() -> bool {
	return state.is_full && !state.is_fresh
}

begin_frame :: proc() {
	state.is_fresh = state.is_full
	if !state.is_full do return

	clear(&state.regions)
	state.pen = {}
	state.row_height = 0
	state.is_full = false
}

start :: proc() {
	state.atlas = render.make_texture({ATLAS_SIZE_PIXELS, ATLAS_SIZE_PIXELS}, .R8Unorm)
}

draw :: proc(name: string, size_pixels: f32, rect, clip: [4]f32, color: [4]f32) {
	key := [2]u64{hash.fnv64a(transmute([]u8)name), u64(size_pixels * SIZE_STEPS_PER_PIXEL)}
	region, ok := state.regions[key]

	if !ok {
		region = rasterize(name, size_pixels)
		if !state.is_full do state.regions[key] = region
	}

	if region.z == 0 do return

	width := f32(region.z)
	height := f32(region.w)
	left := math.round((rect.x + rect.z - width) / 2)
	top := math.round((rect.y + rect.w - height) / 2)
	uv :=
		[4]f32{f32(region.x), f32(region.y), f32(region.x + region.z), f32(region.y + region.w)} /
		ATLAS_SIZE_PIXELS

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
rasterize :: proc(name: string, size_pixels: f32) -> [4]int {
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
	width := int(math.ceil(f64(size.width))) + 2 * PADDING_PIXELS
	height := int(math.ceil(f64(size.height))) + 2 * PADDING_PIXELS
	region, ok := allocate(width, height)

	if !ok {
		state.is_full = true
		return {}
	}

	pixels := make([]u8, width * height * BYTES_PER_PIXEL, context.temp_allocator)
	space := mac.CGColorSpaceCreateDeviceRGB()
	defer mac.CGColorSpaceRelease(space)
	bitmap_context := mac.CGBitmapContextCreate(
		raw_data(pixels),
		uint(width),
		uint(height),
		BITS_PER_CHANNEL,
		uint(width * BYTES_PER_PIXEL),
		space,
		ALPHA_PREMULTIPLIED_LAST,
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
	target := NS.Rect{{PADDING_PIXELS, PADDING_PIXELS}, size}
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

	mask := make([]u8, width * height, context.temp_allocator)
	for index in 0 ..< width * height do mask[index] = pixels[index * BYTES_PER_PIXEL + 3]

	render.upload_texture(state.atlas, region, raw_data(mask), width)

	return region
}

@(private)
allocate :: proc(width, height: int) -> ([4]int, bool) {
	if state.pen.x + width > ATLAS_SIZE_PIXELS {
		state.pen = {0, state.pen.y + state.row_height}
		state.row_height = 0
	}

	if state.pen.y + height > ATLAS_SIZE_PIXELS do return {}, false

	region := [4]int{state.pen.x, state.pen.y, width, height}
	state.pen.x += width
	state.row_height = max(state.row_height, height)

	return region, true
}
