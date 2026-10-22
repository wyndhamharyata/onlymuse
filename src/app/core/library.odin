package core

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"
import "om:ui"

// Where a box inside a scrolling page starts, in the page's content, as of last frame.
offset_in_page :: proc(page, box: ^ui.Box) -> f32 {
	return box.rect.y - page.rect.y - page.style.padding.y + page.scroll
}

// The library's songs, every page of them, read once per answer version. The command palette shares them.
list_library_songs :: proc() -> (songs: []Catalog_Song, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/songs?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)
	if is_stale && phase == .Ready do read_library_songs(data, bodies)

	return data.songs, signature, phase
}

list_library_albums :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/albums?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)
	if is_stale && phase == .Ready do read_cards(data, bodies)

	return data.cards, signature, phase
}

// Two library artists can share one catalog artist, such as a name spelled two ways. It shows once.
list_library_artists :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/artists?sort=name&include=catalog"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, is_stale := find_page_data(path, signature, phase)

	if is_stale && phase == .Ready {
		allocator := page_allocator(data)
		cards := make([dynamic]apple.Card, allocator)
		seen := make(map[string]bool, context.temp_allocator)

		for body in bodies {
			for artist in apple.to_resources(body, allocator) {
				catalog := apple.list_related(artist, "catalog")
				if len(catalog) == 0 || seen[catalog[0].id] do continue

				seen[catalog[0].id] = true
				append(&cards, apple.to_card(catalog[0]))
			}
		}

		data.cards = cards[:]
	}

	return data.cards, signature, phase
}

// Favourite Songs is the one library playlist a person can neither edit nor delete. The sidebar leaves it out.
list_playlists :: proc(
) -> (
	playlists: []apple.Card,
	favourite_songs_id: string,
	phase: apple.Phase,
) {
	path := "/v1/me/library/playlists?limit=100"
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		allocator := page_allocator(data)
		cards := make([dynamic]apple.Card, allocator)

		for resource in apple.to_resources(watched.body, allocator) {
			can_edit, has_edit := resource.attributes.can_edit.?
			can_delete, has_delete := resource.attributes.can_delete.?

			if has_edit && has_delete && !can_edit && !can_delete {
				data.link_id = resource.id
				continue
			}

			append(&cards, apple.to_card(resource))
		}

		data.cards = cards[:]
	}

	return data.cards, data.link_id, watched.phase
}

// Every page of a library list. The link to the next page keeps only its offset.
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

		next_offset := find_next_offset(
			fmt.tprintf("%s%slimit=100&offset=%s", path, separator, offset),
			watched,
		)
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
		for resource in apple.to_resources(body, allocator) {
			append(&songs, apple.to_library_song(resource))
		}
	}

	data.songs = songs[:]
}

read_cards :: proc(data: ^Page_Data, bodies: []string) {
	allocator := page_allocator(data)
	cards := make([dynamic]apple.Card, allocator)

	for body in bodies {
		for card in apple.list_cards(apple.to_resources(body, allocator), allocator) {
			append(&cards, card)
		}
	}

	data.cards = cards[:]
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
	if found, ok := next_offsets[path]; ok && found.version == watched.version {
		return found.offset
	}

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
