// Artwork from Apple's image server: saved on disk once, decoded at the size drawn, kept on the GPU
// while it is recent.
package image

import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import MTL "vendor:darwin/Metal"
import "om:net"

// The covers kept on the GPU, in bytes. One drawn in the last frame is never unloaded, so a page with more keeps them all.
MAX_IMAGE_BYTES :: 64 * 1024 * 1024

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
	crop:             Crop,
	bytes:            int,
}

// The shape a picture is cut to before it goes to the GPU, width over height, kept around focus_y from its top.
// An aspect of 0 keeps the whole picture. A picture shown cut then costs only the part shown.
Crop :: struct {
	aspect:  f32,
	focus_y: f32,
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
	crop:        Crop,
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
	// A thread pool keeps each finished task until it is taken.
	for _ in thread.pool_pop_done(&state.pool) {}
	start_waiting()
	unload_extra()
}

// True while an image fades in.
is_animating :: proc() -> bool {
	return state.is_fading
}

// The texture for url, or a file path, at size_pixels, or nil until it is loaded. opacity fades a new image in.
find :: proc(url: string, size_pixels: int, crop := Crop{}) -> (texture: ^MTL.Texture, opacity: f32) {
	crop_key := u64(crop.aspect * 100) << 40 | u64(crop.focus_y * 100) << 52
	key := hash.fnv64a(transmute([]u8)url) ~ u64(size_pixels) ~ crop_key
	entry, ok := state.entries[key]

	if !ok {
		entry = new(Entry)
		entry.url = strings.clone(url)
		entry.size_pixels = size_pixels
		entry.crop = crop
		entry.family = to_family(url)
		state.entries[key] = entry
	}

	entry.last_drawn_frame = state.frame_index

	if entry.phase != .Ready {
		if stand_in, has_stand_in := find_stand_in(entry.family, key, crop); has_stand_in {
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
		slash := strings.last_index_byte(url, '/')
		equals := strings.last_index_byte(url, '=')
		// Apple puts the size after the last slash. YouTube's googleusercontent.com puts it after "=", and the
		// picture's ID before it, so the slash would make every YouTube picture one family.
		if equals > slash {
			family = url[:equals]
		} else if slash > 0 {
			family = url[:slash]
		}
	}

	return hash.fnv64a(transmute([]u8)family)
}

@(private)
// Only a size of the same crop stands in. The same picture cropped square for a song row would show zoomed
// in a wide tile, then jump when the tile's own loads.
find_stand_in :: proc(family, key: u64, crop: Crop) -> (^Entry, bool) {
	stand_in_key, ok := state.families[family]
	if !ok || stand_in_key == key do return nil, false

	stand_in := state.entries[stand_in_key] or_else nil
	if stand_in == nil || stand_in.phase != .Ready || stand_in.crop != crop do return nil, false

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
		job^ = Job{key = key, url = strings.clone(entry.url), size_pixels = entry.size_pixels, crop = entry.crop}
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
			entry.bytes = int(job.texture->width() * job.texture->height()) * 4
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
	ready_bytes := 0
	for _, entry in state.entries do if entry.phase == .Ready do ready_bytes += entry.bytes

	if ready_bytes <= MAX_IMAGE_BYTES do return

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

	for candidate in candidates {
		if ready_bytes <= MAX_IMAGE_BYTES do break

		entry := state.entries[candidate.key]
		ready_bytes -= entry.bytes
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

// The colour of the picture at url at whichever size loaded, false until one has.
find_color :: proc(url: string) -> (Color, bool) {
	key, ok := state.families[to_family(url)]
	if !ok do return {}, false

	entry := state.entries[key] or_else nil
	if entry == nil || entry.phase != .Ready do return {}, false

	return entry.color, true
}
