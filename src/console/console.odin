// The errors and refused requests that the Console page lists. Any thread can call this package.
package console

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "om:platform"

Entry :: struct {
	at:     time.Time,
	// The part of the app that reported the entry, such as "Apple" or "Helper".
	source: string,
	text:   string,
}

// Past this count, each new entry deletes the oldest one.
MAX_ENTRY_COUNT :: 500

// @(private) hides state from other packages.
@(private)
state: struct {
	mutex:   sync.Mutex,
	entries: [dynamic]Entry,
	// The version counts up with each change, so the page knows that it has something new.
	version: int,
}

// add also writes each entry to stderr. An entry keeps source without a copy,
// so source must be a constant, such as "Apple".
add :: proc(source: string, format: string, args: ..any) {
	text := fmt.aprintf(format, ..args)
	fmt.eprintfln("%s: %s", source, text)

	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&state.mutex)

		if len(state.entries) >= MAX_ENTRY_COUNT {
			delete(state.entries[0].text)
			ordered_remove(&state.entries, 0)
		}

		append(&state.entries, Entry{time.now(), source, text})
		state.version += 1
	}

	platform.wake()
}

// A copy of every entry, oldest first, in allocator. On the main thread, the memory of
// context.temp_allocator lasts until the next frame starts.
list :: proc(allocator := context.temp_allocator) -> []Entry {
	sync.guard(&state.mutex)
	entries := make([]Entry, len(state.entries), allocator)

	for entry, index in state.entries {
		entries[index] = {entry.at, entry.source, strings.clone(entry.text, allocator)}
	}

	return entries
}

clear_entries :: proc() {
	sync.guard(&state.mutex)

	for entry in state.entries do delete(entry.text)
	clear(&state.entries)
	state.version += 1
}

// A status as the person reads it, such as "429, too many requests". 0 means no answer came.
to_status_text :: proc(status: int) -> string {
	switch status {
	case 0:
		return "no answer"
	case 401, 403:
		return fmt.tprintf("%d, sign-in refused", status)
	case 404:
		return "404, not found"
	case 429:
		return "429, too many requests"
	case 500 ..= 599:
		return fmt.tprintf("%d, the server failed", status)
	}

	return fmt.tprintf("%d", status)
}
