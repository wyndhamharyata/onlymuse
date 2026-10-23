package matching

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:app/core"
import "om:apple"
import "om:store"
import "om:youtube"

Match_State :: enum {
	Checking,
	Found,
	Missing,
}

// Raise this whenever is_same_recording changes, so every saved match is made again.
MATCH_RULE_VERSION :: "3"

@(private)
matcher: struct {
	mutex:         sync.Mutex,
	found:         map[string]core.Catalog_Song,
	missing:       map[string]bool,
	checking:      map[string]bool,
	failed:        map[string]time.Tick,
	resume_at:     time.Tick,
	refusal_count: int,
	pending:       [dynamic]^Match_Job,
	pool:          thread.Pool,
	is_started:    bool,
}

@(private = "file")
library_index: struct {
	signature: int,
	is_built:  bool,
	arena:     virtual.Arena,
	by_title:  map[string][dynamic]core.Catalog_Song,
}

start_match_rule :: proc() {
	saved_rule, _ := store.find_state("matchRule", context.temp_allocator)
	if saved_rule == MATCH_RULE_VERSION do return

	store.delete_matches()
	store.save_state("matchRule", MATCH_RULE_VERSION)
}

watch_match :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, Match_State) {
	video_id := youtube.to_video_id(song.id)
	if video_id == "" do return song, .Found

	sync.guard(&matcher.mutex)

	if found, ok := matcher.found[video_id]; ok do return found, .Found
	if video_id in matcher.missing do return song, .Missing
	if video_id in matcher.checking do return song, .Checking

	if retry_at, ok := matcher.failed[video_id]; ok {
		if time.tick_diff(time.tick_now(), retry_at) > 0 do return song, .Checking
		delete_key(&matcher.failed, video_id)
	}

	if store.is_match_rejected(video_id) {
		matcher.missing[strings.clone(video_id)] = true
		return song, .Missing
	}

	if saved, ok := store.find_match(video_id, context.temp_allocator); ok {
		keep_match(video_id, saved)
		return find_match_locked(song, video_id)
	}

	library_song, is_in_library, library_phase := find_library_match(song)
	if library_phase == .Loading do return song, .Checking

	if is_in_library {
		save_match_answer(video_id, library_song, true)
		return find_match_locked(song, video_id)
	}

	start_matching(song, video_id)

	return song, .Checking
}

@(private = "file")
find_library_match :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, bool, apple.Phase) {
	songs, signature, phase := core.watch_library_songs()
	is_index_stale := !library_index.is_built || signature != library_index.signature

	if phase != .Ready do return {}, false, phase

	if is_index_stale {
		core.retire_arena(library_index.arena)
		library_index.arena = {}
		library_index.by_title = {}

		_ = virtual.arena_init_growing(&library_index.arena)
		allocator := virtual.arena_allocator(&library_index.arena)
		library_index.by_title = make(map[string][dynamic]core.Catalog_Song, allocator)
		library_index.signature = signature
		library_index.is_built = true

		for library_song in songs {
			if !is_catalog_id(library_song.id) do continue

			copied := core.copy_song(library_song, allocator)

			for key in list_title_keys(library_song.name) {
				if key not_in library_index.by_title {
					library_index.by_title[strings.clone(key, allocator)] = make(
						[dynamic]core.Catalog_Song,
						allocator,
					)
				}

				append(&library_index.by_title[key], copied)
			}
		}
	}

	candidates := make([dynamic]core.Catalog_Song, context.temp_allocator)

	for key in list_title_keys(song.name) {
		if list, ok := library_index.by_title[key]; ok do append(&candidates, ..list[:])
	}

	best, is_found := find_closest(song, candidates[:])

	return best, is_found, .Ready
}

@(private = "file")
find_match_locked :: proc(
	song: core.Catalog_Song,
	video_id: string,
) -> (
	core.Catalog_Song,
	Match_State,
) {
	if found, ok := matcher.found[video_id]; ok do return found, .Found

	return song, .Missing
}

reject_match :: proc(song: core.Catalog_Song) {
	video_id := youtube.to_video_id(song.id)
	if video_id == "" do return

	store.save_rejected_match(video_id)

	sync.guard(&matcher.mutex)
	delete_key(&matcher.found, video_id)
	if video_id not_in matcher.missing do matcher.missing[strings.clone(video_id)] = true
}

allow_match :: proc(song: core.Catalog_Song) {
	video_id := youtube.to_video_id(song.id)
	store.delete_rejected_match(video_id)

	sync.guard(&matcher.mutex)
	delete_key(&matcher.missing, video_id)
}

is_match_rejected :: proc(song: core.Catalog_Song) -> bool {
	video_id := youtube.to_video_id(song.id)

	return video_id != "" && store.is_match_rejected(video_id)
}

to_youtube_song :: proc(song: core.Catalog_Song) -> core.Catalog_Song {
	youtube_song := song
	youtube_song.id = fmt.tprintf("%s%s", youtube.SONG_ID_PREFIX, song.youtube_id)
	youtube_song.youtube_id = ""
	youtube_song.is_lossless = false

	return youtube_song
}

watch_playable :: proc(song: core.Catalog_Song) -> core.Catalog_Song {
	found, state := watch_match(song)

	return found if state == .Found else song
}

is_same_queue_song :: proc(queue_song, song: core.Catalog_Song) -> bool {
	return queue_song.id == song.id || queue_song.id == watch_playable(song).id
}

@(private = "file")
keep_match :: proc(video_id, saved: string) {
	key := strings.clone(video_id)

	if saved == "" {
		matcher.missing[key] = true
		return
	}

	song: core.Catalog_Song

	if json.unmarshal_string(saved, &song) != nil {
		matcher.missing[key] = true
		return
	}

	song.youtube_id = key
	matcher.found[key] = song
}

@(private)
save_match_answer :: proc(video_id: string, song: core.Catalog_Song, is_found: bool) {
	saved := ""

	if is_found {
		bytes, _ := json.marshal(song, allocator = context.temp_allocator)
		saved = string(bytes)
	}

	store.save_match(video_id, saved)
	keep_match(video_id, saved)
}

// Catalog IDs are digits. A song uploaded from a Mac has only a library ID.
is_catalog_id :: proc(id: string) -> bool {
	if id == "" do return false
	for character in id do if character < '0' || character > '9' do return false

	return true
}
