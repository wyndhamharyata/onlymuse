package image

import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:net"
import MTL "vendor:darwin/Metal"

MAX_IMAGE_BYTES :: 64 * 1024 * 1024

WORKER_COUNT :: 6

FAILED_RETRY_WAIT :: 30 * time.Second

FADE_IN_SECONDS :: 0.25

@(private)
CROP_KEY_STEPS :: 100
@(private)
CROP_ASPECT_SHIFT :: 40
@(private)
CROP_FOCUS_SHIFT :: 52

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
	family:           u64,
	had_stand_in:     bool,
	color:            Color,
	crop:             Crop,
	bytes:            int,
}

Crop :: struct {
	aspect:  f32,
	focus_y: f32,
}

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
	color:       Color,
}

@(private)
state: struct {
	folder:        string,
	entries:       map[u64]^Entry,
	waiting:       [dynamic]u64,
	loading_count: int,
	pool:          thread.Pool,
	mutex:         sync.Mutex,
	finished:      [dynamic]^Job,
	families:      map[u64]u64,
	frame_index:   int,
	is_animating:  bool,
}

start :: proc() {
	home := os.get_env("HOME", context.temp_allocator)
	state.folder, _ = filepath.join(
		{home, "Library", "Caches", "onlymuse-native", "images"},
		context.allocator,
	)
	os.make_directory_all(state.folder)

	net.start()
	thread.pool_init(&state.pool, context.allocator, WORKER_COUNT)
	thread.pool_start(&state.pool)
}

begin_frame :: proc() {
	state.frame_index += 1
	state.is_animating = false

	take_finished()
	for _ in thread.pool_pop_done(&state.pool) {}
	start_waiting()
	unload_extra()
}

is_animating :: proc() -> bool {
	return state.is_animating
}

watch :: proc(
	url: string,
	size_pixels: int,
	crop := Crop{},
) -> (
	texture: ^MTL.Texture,
	opacity: f32,
) {
	crop_key :=
		(u64(crop.aspect * CROP_KEY_STEPS) << CROP_ASPECT_SHIFT) |
		(u64(crop.focus_y * CROP_KEY_STEPS) << CROP_FOCUS_SHIFT)
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

	stand_in: ^Entry
	has_stand_in: bool
	if entry.phase != .Ready do stand_in, has_stand_in = find_stand_in(entry.family, key, crop)

	if has_stand_in {
		entry.had_stand_in = true
		stand_in.last_drawn_frame = state.frame_index
		if entry.phase == .Waiting do append(&state.waiting, key)

		return stand_in.texture, 1
	}

	switch entry.phase {
	case .Waiting:
		append(&state.waiting, key)
	case .Loading:
	case .Failed:
		if time.tick_since(entry.failed_time) > FAILED_RETRY_WAIT do entry.phase = .Waiting
	case .Ready:
		if entry.had_stand_in do return entry.texture, 1

		seconds := f32(time.duration_seconds(time.tick_since(entry.ready_time)))
		opacity = min(1, seconds / FADE_IN_SECONDS)
		if opacity < 1 do state.is_animating = true

		return entry.texture, opacity
	}

	return nil, 0
}

// Apple puts the size after the last slash. googleusercontent.com puts it after "=".
@(private)
to_family :: proc(url: string) -> u64 {
	if strings.has_prefix(url, "/") do return hash.fnv64a(transmute([]u8)url)

	slash := strings.last_index_byte(url, '/')
	equals := strings.last_index_byte(url, '=')
	family := url

	if equals > slash {
		family = url[:equals]
	} else if slash > 0 {
		family = url[:slash]
	}

	return hash.fnv64a(transmute([]u8)family)
}

@(private)
find_stand_in :: proc(family, key: u64, crop: Crop) -> (^Entry, bool) {
	stand_in_key, ok := state.families[family]
	if !ok || stand_in_key == key do return nil, false

	stand_in := state.entries[stand_in_key] or_else nil
	is_usable_stand_in := stand_in != nil && stand_in.phase == .Ready && stand_in.crop == crop
	if !is_usable_stand_in do return nil, false

	return stand_in, true
}

@(private)
start_waiting :: proc() {
	#reverse for key in state.waiting {
		if state.loading_count >= WORKER_COUNT do break

		entry := state.entries[key] or_else nil
		is_wanted := entry != nil && entry.phase == .Waiting && is_on_screen(entry)
		if !is_wanted do continue

		entry.phase = .Loading
		state.loading_count += 1

		job := new(Job)
		job^ = Job {
			key         = key,
			url         = strings.clone(entry.url),
			size_pixels = entry.size_pixels,
			crop        = entry.crop,
		}
		thread.pool_add_task(&state.pool, context.allocator, fetch_image, job)
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
			entry.bytes = int(job.texture->width() * job.texture->height()) * BYTES_PER_PIXEL
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
		if entry.phase == .Ready && !is_on_screen(entry) {
			append(&candidates, Candidate{key, entry.last_drawn_frame})
		}
	}

	slice.sort_by(
		candidates[:],
		proc(a, b: Candidate) -> bool {return a.last_drawn_frame < b.last_drawn_frame},
	)

	for candidate in candidates {
		if ready_bytes <= MAX_IMAGE_BYTES do break

		entry := state.entries[candidate.key]
		ready_bytes -= entry.bytes

		if state.families[entry.family] == candidate.key {
			delete_key(&state.families, entry.family)
		}

		// A command buffer keeps the textures it draws alive until the GPU is done.
		entry.texture->release()
		delete(entry.url)
		free(entry)
		delete_key(&state.entries, candidate.key)
	}
}

@(private)
is_on_screen :: proc(entry: ^Entry) -> bool {
	return entry.last_drawn_frame >= state.frame_index - 1
}

list_counts :: proc() -> (ready, total: int) {
	for _, entry in state.entries do if entry.phase == .Ready do ready += 1

	return ready, len(state.entries)
}

find_color :: proc(url: string) -> (Color, bool) {
	key, ok := state.families[to_family(url)]
	if !ok do return {}, false

	entry := state.entries[key] or_else nil
	if entry == nil || entry.phase != .Ready do return {}, false

	return entry.color, true
}
