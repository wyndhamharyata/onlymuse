// Artwork from Apple's image server: saved on disk once, decoded at the size drawn, kept on the GPU
// while it is recent.
package image

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import MTL "vendor:darwin/Metal"
import "om:mac"
import "om:net"
import "om:platform"
import "om:render"

// Images kept on the GPU. One drawn in the last frame is never unloaded, so a page with more keeps them all.
MAX_IMAGE_COUNT :: 160
// Downloads and decodes at once, on their own threads.
WORKER_COUNT :: 6
// A failed image is asked for again this much later.
RETRY_LATER :: 30 * time.Second
FADE_IN_SECONDS :: 0.25

@(private)
Phase :: enum {
	Waiting,
	Loading,
	Ready,
	Failed,
}

@(private)
Entry :: struct {
	phase:            Phase,
	url:              string,
	size_pixels:      int,
	texture:          ^MTL.Texture,
	last_drawn_frame: int,
	ready_time:       time.Tick,
	failed_time:      time.Tick,
}

@(private)
Job :: struct {
	key:         u64,
	url:         string,
	size_pixels: int,
	texture:     ^MTL.Texture,
}

@(private)
state: struct {
	folder:       string,
	entries:      map[u64]^Entry,
	// Newest last, so the covers asked for most recently load first.
	waiting:      [dynamic]u64,
	loading_count: int,
	pool:         thread.Pool,
	mutex:        sync.Mutex,
	finished:     [dynamic]^Job,
	frame_index:  int,
	is_fading:    bool,
}

start :: proc() {
	home := os.get_env("HOME", context.temp_allocator)
	state.folder, _ = filepath.join({home, "Library", "Caches", "onlymuse-native", "images"}, context.allocator)
	os.make_directory_all(state.folder)
	net.start()
	thread.pool_init(&state.pool, context.allocator, WORKER_COUNT)
	thread.pool_start(&state.pool)
}

// Called once a frame before any image is drawn. Takes in finished loads and starts waiting ones.
begin_frame :: proc() {
	state.frame_index += 1
	state.is_fading = false

	take_finished()
	start_waiting()
	unload_extra()
}

// True while an image fades in.
is_animating :: proc() -> bool {
	return state.is_fading
}

// The texture for url, or a file path, at size_pixels, or nil until it is loaded. opacity fades a new image in.
find :: proc(url: string, size_pixels: int) -> (texture: ^MTL.Texture, opacity: f32) {
	key := hash.fnv64a(transmute([]u8)url) ~ u64(size_pixels)
	entry, ok := state.entries[key]

	if !ok {
		entry = new(Entry)
		entry.url = strings.clone(url)
		entry.size_pixels = size_pixels
		state.entries[key] = entry
	}

	entry.last_drawn_frame = state.frame_index

	switch entry.phase {
	case .Waiting:
		append(&state.waiting, key)
	case .Loading:
	case .Failed:
		if time.tick_since(entry.failed_time) > RETRY_LATER do entry.phase = .Waiting
	case .Ready:
		seconds := f32(time.duration_seconds(time.tick_since(entry.ready_time)))
		opacity = min(1, seconds / FADE_IN_SECONDS)
		if opacity < 1 do state.is_fading = true

		return entry.texture, opacity
	}

	return nil, 0
}

@(private)
start_waiting :: proc() {
	// Last frame's requests. A cover scrolled past before it started is not loaded.
	#reverse for key in state.waiting {
		if state.loading_count >= WORKER_COUNT do break

		entry := state.entries[key] or_else nil
		if entry == nil || entry.phase != .Waiting || entry.last_drawn_frame < state.frame_index - 1 do continue

		entry.phase = .Loading
		state.loading_count += 1
		job := new(Job)
		job^ = Job{key = key, url = strings.clone(entry.url), size_pixels = entry.size_pixels}
		thread.pool_add_task(&state.pool, context.allocator, load, job)
	}
	clear(&state.waiting)
}

@(private)
take_finished :: proc() {
	sync.guard(&state.mutex)

	for job in state.finished {
		state.loading_count -= 1
		entry := state.entries[job.key] or_else nil

		if entry == nil {
			if job.texture != nil do job.texture->release()
		} else if job.texture == nil {
			entry.phase = .Failed
			entry.failed_time = time.tick_now()
		} else {
			entry.phase = .Ready
			entry.texture = job.texture
			entry.ready_time = time.tick_now()
		}

		delete(job.url)
		free(job)
	}
	clear(&state.finished)
}

@(private)
unload_extra :: proc() {
	ready_count := 0
	for _, entry in state.entries do if entry.phase == .Ready do ready_count += 1

	if ready_count <= MAX_IMAGE_COUNT do return

	Candidate :: struct {
		key:              u64,
		last_drawn_frame: int,
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)

	for key, entry in state.entries {
		is_on_screen := entry.last_drawn_frame >= state.frame_index - 1
		if entry.phase == .Ready && !is_on_screen do append(&candidates, Candidate{key, entry.last_drawn_frame})
	}

	slice.sort_by(candidates[:], proc(a, b: Candidate) -> bool {return a.last_drawn_frame < b.last_drawn_frame})

	for candidate in candidates[:min(len(candidates), ready_count - MAX_IMAGE_COUNT)] {
		entry := state.entries[candidate.key]
		// A command buffer keeps the textures it draws alive until the GPU is done.
		entry.texture->release()
		delete(entry.url)
		free(entry)
		delete_key(&state.entries, candidate.key)
	}
}

// Counts for the bench.
count :: proc() -> (ready, total: int) {
	for _, entry in state.entries do if entry.phase == .Ready do ready += 1

	return ready, len(state.entries)
}

// Runs on a worker thread.
@(private)
load :: proc(task: thread.Task) {
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
		if !os.exists(path) && !download(job.url, path) do return
	}

	job.texture = decode(path, job.size_pixels)
}

@(private)
download :: proc(url, path: string) -> bool {
	response := net.fetch(url, allocator = context.temp_allocator)

	if response.status != 200 || !strings.has_prefix(response.content_type, "image/") do return false

	// The file takes its name once complete, so a quit halfway never makes a broken image.
	part_path := fmt.tprintf("%s.part", path)
	if os.write_entire_file(part_path, response.body) != nil do return false

	return os.rename(part_path, path) == nil
}

@(private)
decode :: proc(path: string, size_pixels: int) -> ^MTL.Texture {
	url := mac.CFURLCreateFromFileSystemRepresentation(nil, raw_data(path), len(path), false)
	defer mac.CFRelease(url)
	source := mac.CGImageSourceCreateWithURL(url, nil)
	if source == nil do return nil
	defer mac.CFRelease(source)

	max_size := i32(size_pixels)
	size_number := mac.CFNumberCreate(nil, mac.NUMBER_INT32, &max_size)
	defer mac.CFRelease(size_number)
	keys := []mac.Type_Ref{mac.kCGImageSourceCreateThumbnailFromImageAlways, mac.kCGImageSourceThumbnailMaxPixelSize, mac.kCGImageSourceCreateThumbnailWithTransform}
	values := []mac.Type_Ref{mac.kCFBooleanTrue, size_number, mac.kCFBooleanTrue}
	options := mac.make_dictionary(keys, values)
	defer mac.CFRelease(options)

	// ImageIO decodes straight to this size, so a large file never sits in memory whole.
	image := mac.CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	if image == nil do return nil
	defer mac.CGImageRelease(image)

	width := int(mac.CGImageGetWidth(image))
	height := int(mac.CGImageGetHeight(image))
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	space := mac.CGColorSpaceCreateWithName(mac.kCGColorSpaceSRGB)
	defer mac.CGColorSpaceRelease(space)
	// BGRA with premultiplied alpha, as the shader and BGRA8Unorm expect.
	ctx := mac.CGBitmapContextCreate(raw_data(pixels), uint(width), uint(height), 8, uint(width * 4), space, mac.IMAGE_ALPHA_PREMULTIPLIED_FIRST | mac.BITMAP_BYTE_ORDER_32_LITTLE)
	defer mac.CGContextRelease(ctx)
	mac.CGContextDrawImage(ctx, {{0, 0}, {f64(width), f64(height)}}, image)

	texture := render.make_texture({width, height}, .BGRA8Unorm)
	render.upload_texture(texture, {0, 0, width, height}, raw_data(pixels), width * 4)

	return texture
}
