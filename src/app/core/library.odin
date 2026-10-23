package core

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"
import "om:ui"

to_offset_in_page :: proc(page, box: ^ui.Box) -> f32 {
	return box.rect.y - page.rect.y - page.style.padding.y + page.scroll
}

watch_library_songs :: proc() -> (songs: []Catalog_Song, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/songs?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, needs_read := find_page_data(path, signature, phase)
	if needs_read do read_library_songs(data, bodies)

	return data.songs, signature, phase
}

watch_library_albums :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/albums?sort=name"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, needs_read := find_page_data(path, signature, phase)
	if needs_read do read_cards(data, bodies)

	return data.cards, signature, phase
}

watch_library_artists :: proc() -> (cards: []apple.Card, signature: int, phase: apple.Phase) {
	path := "/v1/me/library/artists?sort=name&include=catalog"
	bodies: []string
	bodies, signature, phase = watch_all_pages(path)
	data, needs_read := find_page_data(path, signature, phase)
	if !needs_read do return data.cards, signature, phase

	allocator := page_allocator(data)
	found := make([dynamic]apple.Card, allocator)
	seen := make(map[string]bool, context.temp_allocator)

	for body in bodies {
		for artist in apple.to_resources(body, allocator) {
			catalog := apple.read_related(artist, "catalog")
			if len(catalog) == 0 || seen[catalog[0].id] do continue

			seen[catalog[0].id] = true
			append(&found, apple.to_card(catalog[0]))
		}
	}

	data.cards = found[:]

	return data.cards, signature, phase
}

// Apple lets no one edit or delete Favourite Songs. The sidebar hides it, so its ID comes apart.
watch_playlists :: proc(
) -> (
	playlists: []apple.Card,
	favourite_songs_id: string,
	phase: apple.Phase,
) {
	path := "/v1/me/library/playlists"
	bodies, signature, watched_phase := watch_all_pages(path)
	data, needs_read := find_page_data(path, signature, watched_phase)
	if !needs_read do return data.cards, data.favourite_songs_id, watched_phase

	allocator := page_allocator(data)
	cards := make([dynamic]apple.Card, allocator)

	for body in bodies {
		for resource in apple.to_resources(body, allocator) {
			can_edit, has_edit := resource.attributes.can_edit.?
			can_delete, has_delete := resource.attributes.can_delete.?

			is_favourite_songs := has_edit && has_delete && !can_edit && !can_delete

			if is_favourite_songs {
				data.favourite_songs_id = resource.id
				continue
			}

			append(&cards, apple.to_card(resource))
		}
	}

	data.cards = cards[:]

	return data.cards, data.favourite_songs_id, watched_phase
}

watch_all_pages :: proc(path: string) -> (bodies: []string, signature: int, phase: apple.Phase) {
	list := make([dynamic]string, context.temp_allocator)
	separator := "&" if strings.contains(path, "?") else "?"
	offset := "0"

	for {
		page_path := fmt.tprintf("%s%slimit=100&offset=%s", path, separator, offset)
		watched := apple.watch(page_path)
		signature = mix_version(signature, watched.version)

		// A saved page can link to a next page that a removal took away. A 404 then ends the list.
		is_past_end := watched.phase == .Failed && watched.status == 404 && offset != "0"
		if is_past_end do break
		if watched.phase != .Ready do return list[:], signature, watched.phase

		append(&list, watched.body)

		next_offset := find_next_offset(page_path, watched)
		if next_offset == "" do break

		offset = next_offset
	}

	return list[:], signature, .Ready
}

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
		for card in apple.to_cards(apple.to_resources(body, allocator), allocator) {
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

@(private = "file")
next_offsets: map[string]Next_Offset

@(private = "file")
find_next_offset :: proc(path: string, watched: apple.Watched) -> string {
	if found, ok := next_offsets[path]; ok && found.version == watched.version {
		return found.offset
	}

	Answer :: struct {
		next: string,
	}
	answer: Answer
	_ = json.unmarshal_string(watched.body, &answer, allocator = context.temp_allocator)
	offset := ""

	if start := strings.index(answer.next, "offset="); start >= 0 {
		offset = answer.next[start + len("offset="):]
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
