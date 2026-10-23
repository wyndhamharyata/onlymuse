package console

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "om:platform"

Entry :: struct {
	at:     time.Time,
	source: string,
	text:   string,
}

MAX_ENTRY_COUNT :: 500

@(private)
state: struct {
	mutex:   sync.Mutex,
	entries: [dynamic]Entry,
	version: int,
}

add :: proc(source: string, format: string, args: ..any) {
	text := fmt.aprintf(format, ..args)
	fmt.eprintfln("%s: %s", source, text)

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
