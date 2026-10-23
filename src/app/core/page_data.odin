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

Page_Data :: struct {
	arena:              virtual.Arena,
	signature:          int,
	phase:              apple.Phase,
	title:              string,
	subtitle:           string,
	detail:             string,
	artwork:            apple.Artwork,
	shelves:            []apple.Shelf,
	cards:              []apple.Card,
	songs:              []Catalog_Song,
	dates:              []string,
	badges:             []string,
	favourite_songs_id: string,
	artist_id:          string,
	release_ids:        string,
	is_in_library:      bool,
	used_at_ms:         i64,
	latest:             []apple.Card,
	library_cards:      []apple.Card,
	similar:            []apple.Card,
	artists:            []apple.Card,
}

page_data: map[string]^Page_Data

find_page_data :: proc(
	key: string,
	signature: int,
	phase: apple.Phase,
) -> (
	data: ^Page_Data,
	needs_read: bool,
) {
	data = page_data[key] or_else nil

	if data == nil {
		data = new(Page_Data)
		page_data[strings.clone(key)] = data
	}

	data.used_at_ms = now_ms()
	is_stale := data.signature != signature || data.phase != phase
	if !is_stale do return data, false

	retire_arena(data.arena)
	data^ = {}
	_ = virtual.arena_init_growing(&data.arena)
	data.signature = signature
	data.phase = phase
	data.used_at_ms = now_ms()

	return data, phase == .Ready
}

mix_version :: proc(a, b: int) -> int {
	return a * 31 + b
}

@(private = "file")
retired_arenas: [dynamic]virtual.Arena

retire_arena :: proc(arena: virtual.Arena) {
	append(&retired_arenas, arena)
}

UNUSED_PAGE_MS :: 5 * 60 * 1000

free_retired_memory :: proc() {
	for &arena in retired_arenas do virtual.arena_destroy(&arena)
	clear(&retired_arenas)
	apple.free_unused_answers()

	now := now_ms()
	unused := make([dynamic]string, context.temp_allocator)
	for key, data in page_data do if now - data.used_at_ms > UNUSED_PAGE_MS do append(&unused, key)

	for key in unused {
		data := page_data[key]
		stored_key, _ := delete_key(&page_data, key)
		retire_arena(data.arena)
		free(data)
		delete(stored_key)
	}
}

HOUR_MS :: 3_600_000
DAY_MS :: 86_400_000
DAY_SECONDS :: 86_400

now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

page_allocator :: proc(data: ^Page_Data) -> mem.Allocator {
	return virtual.arena_allocator(&data.arena)
}
