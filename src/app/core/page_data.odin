package core

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"
import "om:apple"

unmarshal_text :: proc(text: string, value: ^$T) -> json.Unmarshal_Error {
	return json.unmarshal_string(text, value, allocator = context.temp_allocator)
}

// What a page shows, read from its answers once per answer version into an arena of its own.
Page_Data :: struct {
	arena:         virtual.Arena,
	// The versions of the answers it was read from. Another sum reads them again.
	signature:     int,
	phase:         apple.Phase,
	title:         string,
	subtitle:      string,
	detail:        string,
	artwork:       apple.Artwork,
	shelves:       []apple.Shelf,
	cards:         []apple.Card,
	songs:         []Catalog_Song,
	// Each song's release date, beside songs, for an artist's Recent Songs.
	dates:         []string,
	badges:        []string,
	link_id:       string,
	is_in_library: bool,
	// Unix ms of the last frame that asked for it.
	used_at:       i64,
	// The artist page's other shelves.
	latest:        []apple.Card,
	library_cards: []apple.Card,
	similar:       []apple.Card,
}

page_data: map[string]^Page_Data

// The data under key, made again by read when the answers' signature changes.
find_page_data :: proc(
	key: string,
	signature: int,
	phase: apple.Phase,
) -> (
	data: ^Page_Data,
	is_stale: bool,
) {
	data = page_data[key] or_else nil

	if data == nil {
		data = new(Page_Data)
		page_data[strings.clone(key)] = data
	}

	data.used_at = now_ms()
	is_stale = data.signature != signature || data.phase != phase
	if !is_stale do return data, false

	retire_arena(data.arena)
	data^ = {}
	_ = virtual.arena_init_growing(&data.arena)
	data.signature = signature
	data.phase = phase
	data.used_at = now_ms()

	return data, true
}

// A frame's boxes point at the text they show, and draw it when the frame ends. An arena read again during a
// frame, as an answer can arrive while the frame is built, is freed only when the next frame starts.
@(private = "file")
retired_arenas: [dynamic]virtual.Arena

retire_arena :: proc(arena: virtual.Arena) {
	append(&retired_arenas, arena)
}

// A page not shown for this long leaves memory. Its answers stay saved, so it comes back at once.
UNUSED_PAGE_MS :: 5 * 60 * 1000

// Called first in each frame, before any box points at anything.
free_retired_memory :: proc() {
	for &arena in retired_arenas do virtual.arena_destroy(&arena)
	clear(&retired_arenas)
	apple.free_retired_bodies()

	now := now_ms()
	unused := make([dynamic]string, context.temp_allocator)
	for key, data in page_data do if now - data.used_at > UNUSED_PAGE_MS do append(&unused, key)

	for key in unused {
		data := page_data[key]
		// delete_key hands back the map's own copy of the key, which is the one to free.
		stored_key, _ := delete_key(&page_data, key)
		// Its arena goes with the next frame, as this one has yet to start.
		retire_arena(data.arena)
		free(data)
		delete(stored_key)
	}
}

now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

page_allocator :: proc(data: ^Page_Data) -> mem.Allocator {
	return virtual.arena_allocator(&data.arena)
}
