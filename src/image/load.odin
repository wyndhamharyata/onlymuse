package image

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:console"
import "om:mac"
import "om:net"
import "om:platform"
import "om:render"
import MTL "vendor:darwin/Metal"

// This procedure runs on a worker thread.
@(private)
fetch_image :: proc(task: thread.Task) {
	job := cast(^Job)task.data

	defer {
		sync.guard(&state.mutex)
		append(&state.finished, job)
		platform.wake()
	}
	defer free_all(context.temp_allocator)

	// A file path, such as the artwork the helper saves from Music.app, needs no download.
	path := job.url

	if !strings.has_prefix(path, "/") {
		path = fmt.tprintf("%s/%x.jpg", state.folder, hash.fnv64a(transmute([]u8)job.url))
		if !os.exists(path) && !fetch_to_file(job.url, path) do return
	}

	job.texture, job.color = read_texture(path, job.size_pixels, job.crop)
}

@(private)
fetch_to_file :: proc(url, path: string) -> bool {
	response := net.fetch(url, allocator = context.temp_allocator)

	if response.status != 200 {
		console.add("Covers", "%s: %s", url, console.to_status_text(response.status))
		return false
	}
	if !strings.has_prefix(response.content_type, "image/") do return false

	// The file takes its name only when it is complete, so a quit halfway never makes a broken image.
	part_path := fmt.tprintf("%s.part", path)
	if os.write_entire_file(part_path, response.body) != nil do return false

	return os.rename(part_path, path) == nil
}

@(private)
read_texture :: proc(path: string, size_pixels: int, crop: Crop) -> (^MTL.Texture, Color) {
	url := mac.CFURLCreateFromFileSystemRepresentation(nil, raw_data(path), len(path), false)
	defer mac.CFRelease(url)

	source := mac.CGImageSourceCreateWithURL(url, nil)
	if source == nil do return nil, {}
	defer mac.CFRelease(source)

	max_size_pixels := i32(size_pixels)
	size_number := mac.CFNumberCreate(nil, mac.NUMBER_INT32, &max_size_pixels)
	defer mac.CFRelease(size_number)

	keys := []mac.Type_Ref {
		mac.kCGImageSourceCreateThumbnailFromImageAlways,
		mac.kCGImageSourceThumbnailMaxPixelSize,
		mac.kCGImageSourceCreateThumbnailWithTransform,
	}
	values := []mac.Type_Ref{mac.kCFBooleanTrue, size_number, mac.kCFBooleanTrue}
	options := mac.make_dictionary(keys, values)
	defer mac.CFRelease(options)

	// ImageIO decodes straight to this size, so a large file never stays whole in memory.
	thumbnail := mac.CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	if thumbnail == nil do return nil, {}
	defer mac.CGImageRelease(thumbnail)

	image := to_cropped(thumbnail, crop)
	defer if image != thumbnail do mac.CGImageRelease(image)

	width := int(mac.CGImageGetWidth(image))
	height := int(mac.CGImageGetHeight(image))
	pixels := make([]u8, width * height * 4, context.temp_allocator)

	space := mac.CGColorSpaceCreateWithName(mac.kCGColorSpaceSRGB)
	defer mac.CGColorSpaceRelease(space)
	// BGRA with premultiplied alpha, as the shader and BGRA8Unorm expect.
	bitmap_context := mac.CGBitmapContextCreate(
		raw_data(pixels),
		uint(width),
		uint(height),
		8,
		uint(width * 4),
		space,
		mac.IMAGE_ALPHA_PREMULTIPLIED_FIRST | mac.BITMAP_BYTE_ORDER_32_LITTLE,
	)
	defer mac.CGContextRelease(bitmap_context)
	mac.CGContextDrawImage(bitmap_context, {{0, 0}, {f64(width), f64(height)}}, image)

	texture := render.make_texture({width, height}, .BGRA8Unorm)
	render.upload_texture(texture, {0, 0, width, height}, raw_data(pixels), width * 4)

	return texture, to_color(pixels)
}

// The part of image with crop's aspect, centred across and at focus_y down. It returns image itself when image already has that aspect.
@(private)
to_cropped :: proc(image: mac.Image_Ref, crop: Crop) -> mac.Image_Ref {
	width := f64(mac.CGImageGetWidth(image))
	height := f64(mac.CGImageGetHeight(image))
	aspect := f64(crop.aspect)
	if aspect <= 0 || height <= 0 do return image

	rect := mac.Rect{{0, 0}, {width, height}}

	switch {
	case width / height > aspect * 1.01:
		rect.size.width = math.round(height * aspect)
		rect.origin.x = math.round((width - rect.size.width) / 2)
	case width / height < aspect * 0.99:
		rect.size.height = math.round(width / aspect)
		rect.origin.y = math.round((height - rect.size.height) * f64(crop.focus_y))
	case:
		return image
	}

	cropped := mac.CGImageCreateWithImageInRect(image, rect)

	return cropped if cropped != nil else image
}
