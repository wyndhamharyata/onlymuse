// YouTube's lists as the pages read them: home, playlists, an artist, Liked Music, and the YouTube songs kept
// in Apple playlists.
package youtube_lists

import "core:mem/virtual"
import "core:strings"
import "om:app/core"
import "om:app/matching"
import "om:apple"
import "om:youtube"

// A long YouTube list stops after this many parts of about 100 songs.
MAX_YOUTUBE_PART_COUNT :: 50

// YouTube's home sends a few shelves at a time. Mixes for you come in its later parts.
MAX_HOME_PART_COUNT :: 6

@(private = "file")
Parsed_List :: struct {
	arena:   virtual.Arena,
	version: int,
	list:    youtube.List,
	// Unix ms of the last frame that asked for it.
	used_at: i64,
}

// Each answer read once per version, as reading a large one takes milliseconds.
@(private = "file")
parsed_lists: map[string]^Parsed_List

// The list lives until its answer's version changes.
watch_youtube_list :: proc(path: string) -> (youtube.List, apple.Watched) {
	watched := apple.watch(path)
	if watched.phase != .Ready do return {}, watched

	parsed := parsed_lists[path] or_else nil

	if parsed == nil {
		parsed = new(Parsed_List)
		parsed_lists[strings.clone(path)] = parsed
	}

	if parsed.version != watched.version {
		core.retire_arena(parsed.arena)
		parsed^ = {}
		_ = virtual.arena_init_growing(&parsed.arena)
		parsed.version = watched.version
		parsed.list = youtube.to_list(watched.body, virtual.arena_allocator(&parsed.arena))
	}

	parsed.used_at = core.now_ms()

	return parsed.list, watched
}

// Called first in each frame. A list not asked for in a while leaves memory, as a page does.
free_unused_youtube_lists :: proc() {
	now := core.now_ms()
	unused := make([dynamic]string, context.temp_allocator)
	for path, parsed in parsed_lists do if now - parsed.used_at > core.UNUSED_PAGE_MS do append(&unused, path)

	for path in unused {
		parsed := parsed_lists[path]
		// delete_key hands back the map's own copy of the key, which is the one to free.
		stored_path, _ := delete_key(&parsed_lists, path)
		core.retire_arena(parsed.arena)
		free(parsed)
		delete(stored_path)
	}
}

// The songs of every part of a long list, and the first part, which holds the header.
watch_youtube_songs :: proc(path: string) -> (first: youtube.List, songs: []core.Catalog_Song, phase: apple.Phase) {
	watched: apple.Watched
	first, watched = watch_youtube_list(path)
	signature := watched.version
	phase = watched.phase
	parts := make([dynamic]youtube.List, context.temp_allocator)
	if phase == .Ready do append(&parts, first)

	for token := first.continuation; phase == .Ready && token != "" && len(parts) < MAX_YOUTUBE_PART_COUNT; {
		part, part_watched := watch_youtube_list(youtube.continuation_path(token))
		signature = signature * 31 + part_watched.version

		if part_watched.phase == .Loading do phase = .Loading
		if part_watched.phase != .Ready || len(part.songs) == 0 do break

		append(&parts, part)
		token = part.continuation
	}

	data, is_stale := core.find_page_data(path, signature, phase)

	if is_stale && phase == .Ready {
		all := make([dynamic]core.Catalog_Song, core.page_allocator(data))
		for part in parts do for song in part.songs do append(&all, core.copy_song(song, core.page_allocator(data)))
		data.songs = all[:]
	}

	return first, data.songs, phase
}

// The shelves of every part of YouTube's home.
watch_youtube_home :: proc() -> (shelves: []apple.Shelf, signature: int, phase: apple.Phase) {
	first, watched := watch_youtube_list(youtube.browse_path(youtube.HOME_ID))
	signature = watched.version
	if watched.phase != .Ready do return nil, signature, watched.phase

	all := make([dynamic]apple.Shelf, context.temp_allocator)
	append(&all, ..first.shelves)
	token := first.section_continuation

	for part_count := 1; token != "" && part_count < MAX_HOME_PART_COUNT; part_count += 1 {
		part, part_watched := watch_youtube_list(youtube.section_continuation_path(token))
		signature = signature * 31 + part_watched.version
		if part_watched.phase != .Ready do break

		append(&all, ..part.shelves)
		token = part.section_continuation
	}

	return all[:], signature, .Ready
}

youtube_phase_note :: proc(phase: apple.Phase) -> string {
	return "YouTube Music could not be reached." if phase == .Failed else "Loading…"
}

// Apple's shelves with YouTube's between them, one of each in turn.
merge_youtube_shelves :: proc(apple_shelves: []apple.Shelf, allocator := context.allocator) -> (shelves: []apple.Shelf, version: int) {
	youtube_shelves, signature, phase := watch_youtube_home()
	if phase != .Ready do return apple_shelves, signature

	merged := make([dynamic]apple.Shelf, allocator)

	for index in 0 ..< max(len(apple_shelves), len(youtube_shelves)) {
		if index < len(apple_shelves) do append(&merged, apple_shelves[index])
		if index < len(youtube_shelves) do append(&merged, core.copy_shelf(youtube_shelves[index], allocator))
	}

	return merged[:], signature
}

// The YouTube channel with the artist's name, found by YouTube's artist search.
watch_youtube_artist :: proc(name: string) -> youtube.List {
	if name == "" do return {}

	search, _ := watch_youtube_list(youtube.search_path(name, youtube.ARTISTS_FILTER))
	key := matching.to_match_key(name)

	for card in search.cards {
		if card.kind != .YouTube_Artist || matching.to_match_key(card.name) != key do continue

		channel, _ := watch_youtube_list(youtube.browse_path(card.id))

		return channel
	}

	return {}
}
