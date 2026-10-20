package app

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "om:apple"

// What a page shows, read from its answers once per answer version into an arena of its own.
Page_Data :: struct {
	arena:     virtual.Arena,
	// The versions of the answers it was read from. Another sum reads them again.
	signature: int,
	phase:     apple.Phase,
	title:     string,
	subtitle:  string,
	detail:    string,
	artwork:   apple.Artwork,
	shelves:   []apple.Shelf,
	cards:     []apple.Card,
	songs:     []Catalog_Song,
	badges:    []string,
	link_id:   string,
	is_in_library: bool,
	// The artist page's other shelves.
	latest:        []apple.Card,
	library_cards: []apple.Card,
	similar:       []apple.Card,
}

page_data: map[string]^Page_Data

// The data under key, made again by read when the answers' signature changes.
find_page_data :: proc(key: string, signature: int, phase: apple.Phase) -> (data: ^Page_Data, is_stale: bool) {
	data = page_data[key] or_else nil

	if data == nil {
		data = new(Page_Data)
		page_data[strings.clone(key)] = data
	}

	is_stale = data.signature != signature || data.phase != phase
	if !is_stale do return data, false

	virtual.arena_destroy(&data.arena)
	data^ = {}
	_ = virtual.arena_init_growing(&data.arena)
	data.signature = signature
	data.phase = phase

	return data, true
}

page_allocator :: proc(data: ^Page_Data) -> mem.Allocator {
	return virtual.arena_allocator(&data.arena)
}

// Every page of a library list, as the gpuix app asked for them. The link to the next page keeps only its offset.
@(private)
watch_all_pages :: proc(path: string) -> (bodies: []string, signature: int, phase: apple.Phase) {
	list := make([dynamic]string, context.temp_allocator)
	separator := "&" if strings.contains(path, "?") else "?"
	offset := "0"

	for {
		watched := apple.watch(fmt.tprintf("%s%slimit=100&offset=%s", path, separator, offset))
		signature = signature * 31 + watched.version

		if watched.phase != .Ready do return list[:], signature, watched.phase

		append(&list, watched.body)

		Next :: struct {
			next: string,
		}
		next: Next
		_ = json.unmarshal_string(watched.body, &next, allocator = context.temp_allocator)
		start := strings.index(next.next, "offset=")
		if start < 0 do break

		offset = next.next[start + len("offset="):]
		if end := strings.index_byte(offset, '&'); end >= 0 do offset = offset[:end]
	}

	return list[:], signature, .Ready
}

// Songs of every page of a library list.
read_library_songs :: proc(data: ^Page_Data, bodies: []string) {
	allocator := page_allocator(data)
	songs := make([dynamic]Catalog_Song, allocator)

	for body in bodies {
		for resource in apple.to_resources(body, allocator) do append(&songs, apple.to_library_song(resource))
	}

	data.songs = songs[:]
}

read_cards :: proc(data: ^Page_Data, bodies: []string) {
	allocator := page_allocator(data)
	cards := make([dynamic]apple.Card, allocator)

	for body in bodies {
		for card in apple.list_cards(apple.to_resources(body, allocator), allocator) do append(&cards, card)
	}

	data.cards = cards[:]
}

phase_note :: proc(phase: apple.Phase) -> string {
	return "Apple Music could not be reached." if phase == .Failed else "Loading…"
}
