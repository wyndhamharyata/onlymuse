package apple

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:platform"
import "om:store"

Phase :: enum {
	Loading,
	Ready,
	// Apple refused or could not be reached, and nothing was saved.
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
	using watched: Watched,
	path:          string,
	is_checking:   bool,
}

@(private)
cache: struct {
	mutex:   sync.Mutex,
	entries: map[string]^Entry,
	pool:    thread.Pool,
	is_started: bool,
}

// How long an answer counts as fresh, as in the gpuix app. The first rule whose text the path holds applies.
@(private)
fresh_rules := [?]struct {
	part:     string,
	duration: time.Duration,
} {
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

// The answer for path as it stands, without waiting. A saved answer shows at once, and a stale one is
// checked with Apple meanwhile. The body lives until the version changes.
watch :: proc(path: string) -> Watched {
	sync.guard(&cache.mutex)

	if entry, ok := cache.entries[path]; ok do return entry.watched

	if !cache.is_started {
		thread.pool_init(&cache.pool, context.allocator, CHECK_THREAD_COUNT)
		thread.pool_start(&cache.pool)
		cache.is_started = true
	}

	entry := new(Entry)
	entry.path = strings.clone(path)
	cache.entries[entry.path] = entry

	saved, is_saved := store.find_answer(path)
	if is_saved {
		entry.phase = .Ready
		entry.body = saved.body
		entry.version = 1

		age := time.Duration((now_ms() - saved.fetched_at) * i64(time.Millisecond))
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

	answer := send_request(path, .Get)
	if answer.status == 200 do store.save_answer(path, answer.body)

	sync.guard(&cache.mutex)
	entry.is_checking = false
	entry.status = answer.status

	switch {
	case answer.status == 200 && answer.body != entry.body:
		entry.body = answer.body
		entry.version += 1
		entry.phase = .Ready
	case answer.status != 200 && entry.phase == .Loading:
		entry.phase = .Failed
		delete(answer.body)
	case:
		delete(answer.body)
	}

	platform.wake()
}

// Asks Apple again, such as after adding to the library, keeping the saved answer until the new one comes.
refresh :: proc(path: string) {
	sync.guard(&cache.mutex)
	entry, ok := cache.entries[path]
	if !ok || entry.is_checking do return

	entry.is_checking = true
	thread.pool_add_task(&cache.pool, context.allocator, check, entry)
}
