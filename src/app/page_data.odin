package app

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"
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
	// Each song's release date, beside songs, for an artist's Recent Songs.
	dates:     []string,
	badges:    []string,
	link_id:   string,
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
find_page_data :: proc(key: string, signature: int, phase: apple.Phase) -> (data: ^Page_Data, is_stale: bool) {
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
	free_retired_songs()
	apple.free_retired_bodies()
	free_unused_youtube_lists()

	now := now_ms()
	unused := make([dynamic]string, context.temp_allocator)
	for key, data in page_data do if now - data.used_at > UNUSED_PAGE_MS do append(&unused, key)

	for key in unused {
		data := page_data[key]
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

// A song or a card kept in a page's arena, from another arena that lives on its own terms, such as a parsed
// YouTube answer. A page that kept only pointers into one would read freed memory once it was read again.
copy_song :: proc(song: Catalog_Song, allocator := context.allocator) -> Catalog_Song {
	copied := song
	copied.id = strings.clone(song.id, allocator)
	copied.name = strings.clone(song.name, allocator)
	copied.artist_name = strings.clone(song.artist_name, allocator)
	copied.album_name = strings.clone(song.album_name, allocator)
	copied.youtube_id = strings.clone(song.youtube_id, allocator)
	copied.artwork.url = strings.clone(song.artwork.url, allocator)
	copied.artwork.bg_color = strings.clone(song.artwork.bg_color, allocator)
	copied.artwork.text_color1 = strings.clone(song.artwork.text_color1, allocator)

	return copied
}

copy_card :: proc(card: apple.Card, allocator: mem.Allocator) -> apple.Card {
	copied := card
	copied.id = strings.clone(card.id, allocator)
	copied.name = strings.clone(card.name, allocator)
	copied.subtitle = strings.clone(card.subtitle, allocator)
	copied.artwork.url = strings.clone(card.artwork.url, allocator)
	copied.artwork.bg_color = strings.clone(card.artwork.bg_color, allocator)
	copied.artwork.text_color1 = strings.clone(card.artwork.text_color1, allocator)
	copied.song = copy_song(card.song, allocator)

	return copied
}

copy_shelf :: proc(shelf: apple.Shelf, allocator: mem.Allocator) -> apple.Shelf {
	cards := make([]apple.Card, len(shelf.cards), allocator)
	for card, index in shelf.cards do cards[index] = copy_card(card, allocator)

	return {title = strings.clone(shelf.title, allocator), cards = cards, is_youtube = shelf.is_youtube, is_wide = shelf.is_wide}
}

page_allocator :: proc(data: ^Page_Data) -> mem.Allocator {
	return virtual.arena_allocator(&data.arena)
}

// Every page of a library list. The link to the next page keeps only its offset.
@(private)
watch_all_pages :: proc(path: string) -> (bodies: []string, signature: int, phase: apple.Phase) {
	list := make([dynamic]string, context.temp_allocator)
	separator := "&" if strings.contains(path, "?") else "?"
	offset := "0"

	for {
		watched := apple.watch(fmt.tprintf("%s%slimit=100&offset=%s", path, separator, offset))
		signature = signature * 31 + watched.version

		// A saved page can name a next page that is gone, as after songs left a playlist. The list ends there.
		is_past_end := watched.phase == .Failed && watched.status == 404 && offset != "0"
		if is_past_end do break
		if watched.phase != .Ready do return list[:], signature, watched.phase

		append(&list, watched.body)

		next_offset := find_next_offset(fmt.tprintf("%s%slimit=100&offset=%s", path, separator, offset), watched)
		if next_offset == "" do break

		offset = next_offset
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

@(private = "file")
Next_Offset :: struct {
	version: int,
	offset:  string,
}

// The offset of the next page, read once per answer version. Reading 50 KB of JSON each frame took 5 ms.
@(private = "file")
next_offsets: map[string]Next_Offset

@(private = "file")
find_next_offset :: proc(path: string, watched: apple.Watched) -> string {
	if found, ok := next_offsets[path]; ok && found.version == watched.version do return found.offset

	Next :: struct {
		next: string,
	}
	next: Next
	_ = json.unmarshal_string(watched.body, &next, allocator = context.temp_allocator)
	offset := ""

	if start := strings.index(next.next, "offset="); start >= 0 {
		offset = next.next[start + len("offset="):]
		if end := strings.index_byte(offset, '&'); end >= 0 do offset = offset[:end]
	}

	if found, ok := next_offsets[path]; ok {
		delete(found.offset)
		next_offsets[path] = {watched.version, strings.clone(offset)}
	} else {
		next_offsets[strings.clone(path)] = {watched.version, strings.clone(offset)}
	}

	return next_offsets[path].offset
}
