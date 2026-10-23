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
	Failed,
}

Watched :: struct {
	phase:   Phase,
	body:    string,
	version: int,
	status:  int,
}

@(private)
Entry :: struct {
	using watched: Watched,
	path:          string,
	is_checking:   bool,
	used_at_ms:    i64,
	failed_at_ms:  i64,
}

@(private)
FAILED_RETRY_MS :: 30 * 1000

@(private)
UNUSED_ANSWER_MS :: 5 * 60 * 1000

@(private)
retired_bodies: [dynamic]string

@(private)
cache: struct {
	mutex:        sync.Mutex,
	entries:      map[string]^Entry,
	pool:         thread.Pool,
	last_version: int,
}

Source :: proc(path: string, allocator: mem.Allocator) -> Answer

@(private)
sources: map[string]Source

set_source :: proc(prefix: string, source: Source) {
	sources[prefix] = source
}

@(private)
fetch_from_source :: proc(path: string, allocator := context.allocator) -> Answer {
	for prefix, source in sources {
		if strings.has_prefix(path, prefix) {
			return source(path, allocator)
		}
	}

	return fetch_from_apple(path, .Get, allocator)
}

@(private)
fresh_rules := [?]struct {
	part:     string,
	duration: time.Duration,
} {
	{`"FEmusic_home"`, 10 * time.Minute},
	{`"FEmusic_liked`, 0},
	{`"VLLM"`, 0},
	{"youtube/next?", 10 * time.Minute},
	{"youtube/", 24 * time.Hour},
	{"/v1/me/storefront", 30 * 24 * time.Hour},
	{"/lyrics", 30 * 24 * time.Hour},
	{"/syllable-lyrics", 30 * 24 * time.Hour},
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
			thread.pool_add_task(&cache.pool, context.allocator, fetch_entry, entry)
		}

		return entry.watched
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
	thread.pool_add_task(&cache.pool, context.allocator, fetch_entry, entry)

	return entry.watched
}

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
fetch_entry :: proc(task: thread.Task) {
	entry := cast(^Entry)task.data
	path := entry.path
	defer free_all(context.temp_allocator)

	answer := fetch_from_source(path)
	if answer.status == 200 do store.save_answer(path, answer.body)

	sync.guard(&cache.mutex)
	entry.is_checking = false
	entry.status = answer.status
	is_new_body := answer.status == 200 && answer.body != entry.body
	is_failure_with_no_answer := answer.status != 200 && entry.phase != .Ready

	switch {
	case is_new_body:
		if entry.body != "" do append(&retired_bodies, entry.body)
		entry.body = answer.body
		cache.last_version += 1
		entry.version = cache.last_version
		entry.phase = .Ready
	case is_failure_with_no_answer:
		entry.phase = .Failed
		entry.failed_at_ms = now_ms()
		delete(answer.body)
	case:
		delete(answer.body)
	}

	platform.wake()
}

refresh_all :: proc(prefix: string) {
	paths := make([dynamic]string, context.temp_allocator)

	{
		sync.guard(&cache.mutex)
		for path in cache.entries do if strings.has_prefix(path, prefix) do append(&paths, path)
	}

	for path in paths do refresh(path)
}

refresh :: proc(path: string) {
	sync.guard(&cache.mutex)
	entry, ok := cache.entries[path]
	if !ok || entry.is_checking do return

	entry.is_checking = true
	thread.pool_add_task(&cache.pool, context.allocator, fetch_entry, entry)
}

free_unused_answers :: proc() {
	sync.guard(&cache.mutex)

	for body in retired_bodies do delete(body)
	clear(&retired_bodies)

	for _ in thread.pool_pop_done(&cache.pool) {}

	now := now_ms()
	unused := make([dynamic]string, context.temp_allocator)

	for path, entry in cache.entries {
		is_unused := !entry.is_checking && now - entry.used_at_ms > UNUSED_ANSWER_MS
		if is_unused do append(&unused, path)
	}

	for path in unused {
		entry := cache.entries[path]
		delete_key(&cache.entries, path)
		if entry.body != "" do append(&retired_bodies, entry.body)
		delete(entry.path)
		free(entry)
	}
}
