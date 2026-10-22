package apple

import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:platform"
import "om:store"

Phase :: enum {
	Loading,
	Ready,
	// Apple refused, or the app could not reach it. The store holds no saved answer either.
	Failed,
}

Watched :: struct {
	phase:   Phase,
	body:    string,
	// Counts up each time a newer answer replaces the body, so a page knows to read it again.
	version: int,
	status:  int,
}

@(private)
Entry :: struct {
	// using lets entry.phase stand for entry.watched.phase, and watch returns entry.watched whole.
	using watched: Watched,
	path:          string,
	is_checking:   bool,
	// Unix ms of the last watch, so free_retired_bodies can free an answer that no page asked for in a while.
	used_at_ms:    i64,
	// Unix ms of the last failed check.
	failed_at_ms:  i64,
}

// watch asks again for a failed answer when a page watches it this long after, such as once the network is back.
@(private)
FAILED_RETRY_MS :: 30 * 1000

// free_retired_bodies frees an answer that no page watched for this long. It stays saved, so a page asking again finds it at once.
@(private)
UNUSED_ANSWER_MS :: 5 * 60 * 1000

// Bodies replaced or let go during a frame, freed when the next starts, as a page may still read them.
@(private)
retired_bodies: [dynamic]string

@(private)
cache: struct {
	mutex:        sync.Mutex,
	entries:      map[string]^Entry,
	pool:         thread.Pool,
	// Each new body takes the next number as its version. The cache never uses a version twice, so a page that
	// read an answer before the cache let it go never takes a new one for the same.
	last_version: int,
	is_started:   bool,
}

// Another package that answers the paths starting with its prefix, such as src/youtube. It blocks. Its body uses allocator.
Source :: proc(path: string, allocator: mem.Allocator) -> Answer

@(private)
sources: map[string]Source

// A package calls this once at start, before any watch.
add_source :: proc(prefix: string, source: Source) {
	sources[prefix] = source
}

@(private)
send_to_source :: proc(path: string, allocator := context.allocator) -> Answer {
	for prefix, source in sources {
		if strings.has_prefix(path, prefix) {
			return source(path, allocator)
		}
	}

	return send_request(path, .Get, allocator)
}

// How long an answer counts as fresh. The first rule whose text the path holds applies.
@(private)
fresh_rules := [?]struct {
	part:     string,
	duration: time.Duration,
} {


	// YouTube's home, mixes and library, and then the rest of YouTube.
	{`"FEmusic_home"`, 10 * time.Minute},
	{`"FEmusic_liked`, 0},
	{`"VLLM"`, 0},
	{"youtube/next?", 10 * time.Minute},
	{"youtube/", 24 * time.Hour},
	{"/v1/me/storefront", 30 * 24 * time.Hour},
	{"lyrics", 30 * 24 * time.Hour},
	{"/v1/me/recommendations", 10 * time.Minute},
	{"/v1/me/", 0},
	{"/v1/editorial/", 60 * time.Minute},
	{"/search?", 10 * time.Minute},
	{"/v1/catalog/", 24 * time.Hour},
}

@(private)
to_fresh_duration :: proc(path: string) -> time.Duration {
	for rule in fresh_rules do if strings.contains(path, rule.part) do return rule.duration

	return 0
}

@(private)
CHECK_THREAD_COUNT :: 4

// The answer for path as it stands, without waiting. A saved answer shows at once. watch checks a stale one
// with Apple meanwhile. The body lives until the version changes.
watch :: proc(path: string) -> Watched {
	sync.guard(&cache.mutex)

	if entry, ok := cache.entries[path]; ok {
		entry.used_at_ms = now_ms()
		can_retry :=
			entry.phase == .Failed &&
			!entry.is_checking &&
			entry.used_at_ms - entry.failed_at_ms > FAILED_RETRY_MS

		if can_retry {
			entry.is_checking = true
			thread.pool_add_task(&cache.pool, context.allocator, check, entry)
		}

		return entry.watched
	}

	if !cache.is_started {
		thread.pool_init(&cache.pool, context.allocator, CHECK_THREAD_COUNT)
		thread.pool_start(&cache.pool)
		cache.is_started = true
	}

	entry := new(Entry)
	entry.path = strings.clone(path)
	entry.used_at_ms = now_ms()
	cache.entries[entry.path] = entry

	saved, is_saved := store.find_answer(path)

	if is_saved {
		entry.phase = .Ready
		entry.body = saved.body
		cache.last_version += 1
		entry.version = cache.last_version

		age := time.Duration((now_ms() - saved.fetched_at_ms) * i64(time.Millisecond))
		if age < to_fresh_duration(path) do return entry.watched
	}

	entry.is_checking = true
	thread.pool_add_task(&cache.pool, context.allocator, check, entry)

	return entry.watched
}

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

// Runs on a worker. A failed check keeps the saved answer, so the app works offline.
@(private)
check :: proc(task: thread.Task) {
	entry := cast(^Entry)task.data
	path := entry.path
	defer free_all(context.temp_allocator)

	answer := send_to_source(path)
	if answer.status == 200 do store.save_answer(path, answer.body)

	sync.guard(&cache.mutex)
	entry.is_checking = false
	entry.status = answer.status

	switch {
	case answer.status == 200 && answer.body != entry.body:
		if entry.body != "" do append(&retired_bodies, entry.body)
		entry.body = answer.body
		cache.last_version += 1
		entry.version = cache.last_version
		entry.phase = .Ready
	case answer.status != 200 && entry.phase != .Ready:
		entry.phase = .Failed
		entry.failed_at_ms = now_ms()
		delete(answer.body)
	case:
		delete(answer.body)
	}

	platform.wake()
}

// Asks again for every answer whose path starts with prefix, such as YouTube's after a sign-in.
refresh_all :: proc(prefix: string) {
	paths := make([dynamic]string, context.temp_allocator)

	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&cache.mutex)
		for path in cache.entries do if strings.has_prefix(path, prefix) do append(&paths, path)
	}

	for path in paths do refresh(path)
}

// Asks Apple again, such as after adding to the library, keeping the saved answer until the new one comes.
refresh :: proc(path: string) {
	sync.guard(&cache.mutex)
	entry, ok := cache.entries[path]
	if !ok || entry.is_checking do return

	entry.is_checking = true
	thread.pool_add_task(&cache.pool, context.allocator, check, entry)
}

// core calls this first in each frame. It frees the bodies replaced since the last frame. It lets go of answers that no page watched lately.
free_retired_bodies :: proc() {
	sync.guard(&cache.mutex)

	for body in retired_bodies do delete(body)
	clear(&retired_bodies)

	// A thread pool keeps each finished task until pool_pop_done takes it.
	for _ in thread.pool_pop_done(&cache.pool) {}

	now := now_ms()
	unused := make([dynamic]string, context.temp_allocator)

	for path, entry in cache.entries {
		if !entry.is_checking && now - entry.used_at_ms > UNUSED_ANSWER_MS {
			append(&unused, path)
		}
	}

	for path in unused {
		entry := cache.entries[path]
		delete_key(&cache.entries, path)
		// A page may read it in this frame, which did not start yet. So the next frame frees it.
		if entry.body != "" do append(&retired_bodies, entry.body)
		delete(entry.path)
		free(entry)
	}
}
