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
import "om:console"
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
	// The same picture at any size. Apple's URLs differ only in the last part, the size.
	family:           u64,
	// Another size stood in until this one loaded, so it shows at once, with no fade.
	had_stand_in:     bool,
	color:            Color,
}

// A guess at a picture's colour: the average of its pixels, the vivid and bright ones counting most.
// vividness, from 0 to 1, is how colourful the picture is overall. A black and white one is near 0.
Color :: struct {
	rgb:       [3]f32,
	vividness: f32,
}

@(private)
Job :: struct {
	key:         u64,
	url:         string,
	size_pixels: int,
	texture:     ^MTL.Texture,
	color:      Color,
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
	// The entry of each family last loaded, to stand in for a size still loading.
	families:     map[u64]u64,
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
		entry.family = to_family(url)
		state.entries[key] = entry
	}

	entry.last_drawn_frame = state.frame_index

	if entry.phase != .Ready {
		if stand_in, has_stand_in := find_stand_in(entry.family, key); has_stand_in {
			entry.had_stand_in = true
			stand_in.last_drawn_frame = state.frame_index
			if entry.phase == .Waiting do append(&state.waiting, key)

			return stand_in.texture, 1
		}
	}

	switch entry.phase {
	case .Waiting:
		append(&state.waiting, key)
	case .Loading:
	case .Failed:
		if time.tick_since(entry.failed_time) > RETRY_LATER do entry.phase = .Waiting
	case .Ready:
		if entry.had_stand_in do return entry.texture, 1

		seconds := f32(time.duration_seconds(time.tick_since(entry.ready_time)))
		opacity = min(1, seconds / FADE_IN_SECONDS)
		if opacity < 1 do state.is_fading = true

		return entry.texture, opacity
	}

	return nil, 0
}

@(private)
to_family :: proc(url: string) -> u64 {
	family := url
	if !strings.has_prefix(url, "/") {
		if slash := strings.last_index_byte(url, '/'); slash > 0 do family = url[:slash]
	}

	return hash.fnv64a(transmute([]u8)family)
}

@(private)
find_stand_in :: proc(family, key: u64) -> (^Entry, bool) {
	stand_in_key, ok := state.families[family]
	if !ok || stand_in_key == key do return nil, false

	stand_in := state.entries[stand_in_key] or_else nil
	if stand_in == nil || stand_in.phase != .Ready do return nil, false

	return stand_in, true
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
			entry.color = job.color
			entry.ready_time = time.tick_now()
			state.families[entry.family] = job.key
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
		if state.families[entry.family] == candidate.key do delete_key(&state.families, entry.family)
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

	job.texture, job.color = decode(path, job.size_pixels)
}

@(private)
download :: proc(url, path: string) -> bool {
	response := net.fetch(url, allocator = context.temp_allocator)

	if response.status != 200 {
		console.add("Covers", "%s: %s", url, console.to_status_text(response.status))
		return false
	}
	if !strings.has_prefix(response.content_type, "image/") do return false

	// The file takes its name once complete, so a quit halfway never makes a broken image.
	part_path := fmt.tprintf("%s.part", path)
	if os.write_entire_file(part_path, response.body) != nil do return false

	return os.rename(part_path, path) == nil
}

@(private)
decode :: proc(path: string, size_pixels: int) -> (^MTL.Texture, Color) {
	url := mac.CFURLCreateFromFileSystemRepresentation(nil, raw_data(path), len(path), false)
	defer mac.CFRelease(url)
	source := mac.CGImageSourceCreateWithURL(url, nil)
	if source == nil do return nil, {}
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
	if image == nil do return nil, {}
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

	return texture, guess_color(pixels)
}

// From premultiplied BGRA. The pixels go into buckets by hue, each counted by its saturation squared
// times its brightness, so a grey wall or a black border counts little against a red coat. The colour
// is the average of the heaviest hue and the two beside it: an average of every pixel would mix a
// purple sky and an orange sun into brown.
@(private)
guess_color :: proc(pixels: []u8) -> Color {
	HUE_BUCKETS :: 36
	sums: [HUE_BUCKETS][3]f32
	weights: [HUE_BUCKETS]f32
	weight_sum: f32
	count: int

	for index := 0; index + 3 < len(pixels); index += 4 {
		alpha := f32(pixels[index + 3]) / 255
		if alpha < 0.5 do continue

		rgb := [3]f32{f32(pixels[index + 2]), f32(pixels[index + 1]), f32(pixels[index])} / (255 * alpha)
		brightest := max(rgb.r, rgb.g, rgb.b)
		spread := brightest - min(rgb.r, rgb.g, rgb.b)
		count += 1
		if spread <= 0 do continue

		saturation := spread / brightest
		weight := saturation * saturation * brightest
		bucket := min(int(to_hue(rgb, brightest, spread) * HUE_BUCKETS), HUE_BUCKETS - 1)

		sums[bucket] += rgb * weight
		weights[bucket] += weight
		weight_sum += weight
	}

	if count == 0 || weight_sum <= 0 do return {}

	// Hue goes round, so the bucket before the first is the last.
	best, best_weight := 0, f32(0)
	for bucket in 0 ..< HUE_BUCKETS {
		weight := weights[(bucket + HUE_BUCKETS - 1) % HUE_BUCKETS] + weights[bucket] + weights[(bucket + 1) % HUE_BUCKETS]
		if weight > best_weight do best, best_weight = bucket, weight
	}

	sum: [3]f32
	for offset in -1 ..= 1 do sum += sums[(best + offset + HUE_BUCKETS) % HUE_BUCKETS]

	return {sum / best_weight, weight_sum / f32(count)}
}

// In turns, from 0 to 1.
@(private)
to_hue :: proc(rgb: [3]f32, brightest, spread: f32) -> f32 {
	hue: f32
	switch brightest {
	case rgb.r:
		hue = (rgb.g - rgb.b) / spread
	case rgb.g:
		hue = (rgb.b - rgb.r) / spread + 2
	case:
		hue = (rgb.r - rgb.g) / spread + 4
	}
	hue /= 6

	return hue + 1 if hue < 0 else hue
}

// The colour of the picture at url at whichever size loaded, false until one has.
find_color :: proc(url: string) -> (Color, bool) {
	key, ok := state.families[to_family(url)]
	if !ok do return {}, false

	entry := state.entries[key] or_else nil
	if entry == nil || entry.phase != .Ready do return {}, false

	return entry.color, true
}
