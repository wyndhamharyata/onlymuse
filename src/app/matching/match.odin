// Finds the Apple Music song each YouTube song is, on a thread of its own, and keeps the answers in the store.
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

// A YouTube song plays from Apple Music whenever Apple has it. This finds Apple's song, once per video.
Match_State :: enum {
	Checking,
	// Apple has the song.
	Found,
	// Apple has no such song, so it plays from YouTube.
	Missing,
}

// Counts up whenever is_same_recording changes, so the matches saved under an older rule are made again.
// 3 drops the matches an index pointing into freed memory made from garbage.
MATCH_RULE_VERSION :: "3"

@(private)
matcher: struct {
	mutex:           sync.Mutex,
	// By video ID.
	found:           map[string]core.Catalog_Song,
	missing:         map[string]bool,
	checking:        map[string]bool,
	// A song whose search got no answer, and when it may be checked again.
	failed:          map[string]time.Tick,
	// No search starts before this, after Apple refused one.
	resume_at:       time.Tick,
	refusal_count:   int,
	// Songs waiting for the matching thread.
	pending:         [dynamic]^Match_Job,
	pool:            thread.Pool,
	is_started:      bool,
	is_rule_checked: bool,
}

// The library's songs under each of their title keys, made again when the library changes. Main thread only.
// The library page's songs are read again into new memory whenever its phase changes, even with the same
// signature, so the index keeps copies of its own, in its arena.
@(private = "file")
library_index: struct {
	signature: int,
	is_built:  bool,
	arena:     virtual.Arena,
	by_title:  map[string][dynamic]core.Catalog_Song,
}

// The Apple Music song for a YouTube one. An Apple song is its own match. A song in the person's library
// matches with no request. Others wait for the library, then go to the matching thread.
find_match :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, Match_State) {
	video_id := youtube.to_video_id(song.id)
	if video_id == "" do return song, .Found

	sync.guard(&matcher.mutex)

	if !matcher.is_rule_checked {
		matcher.is_rule_checked = true
		saved_rule, _ := store.find_state("matchRule", context.temp_allocator)

		if saved_rule != MATCH_RULE_VERSION {
			store.delete_matches()
			store.save_state("matchRule", MATCH_RULE_VERSION)
		}
	}

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
		save_found_match(video_id, library_song, true)
		return find_match_locked(song, video_id)
	}

	start_matching(song, video_id)

	return song, .Checking
}

@(private = "file")
find_library_match :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, bool, apple.Phase) {
	songs, signature, phase := core.list_library_songs()
	if phase != .Ready do return {}, false, phase

	if !library_index.is_built || signature != library_index.signature {
		core.retire_arena(library_index.arena)
		library_index.arena = {}
		library_index.by_title = {}
		_ = virtual.arena_init_growing(&library_index.arena)
		allocator := virtual.arena_allocator(&library_index.arena)
		library_index.by_title = make(map[string][dynamic]core.Catalog_Song, allocator)
		library_index.signature = signature
		library_index.is_built = true

		for library_song in songs {
			// A song uploaded from a Mac has no catalog ID, and Apple's catalog has nothing to say of it.
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

// The person heard that Apple's song is another one, or Music.app could not play it. The YouTube song then
// always plays from YouTube.
reject_match :: proc(song: core.Catalog_Song) {
	video_id := youtube.to_video_id(song.id)
	if video_id == "" do return

	store.save_rejected_match(video_id)

	// The queue may hold a copy of Apple's song that shares its text, so the text stays.
	sync.guard(&matcher.mutex)
	delete_key(&matcher.found, video_id)
	if video_id not_in matcher.missing do matcher.missing[strings.clone(video_id)] = true
}

// Undoes reject_match. The song is checked against Apple's catalog again.
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

// The YouTube song an Apple match was made from, to play when Apple's will not. Its ID lives for the frame.
to_youtube_song :: proc(song: core.Catalog_Song) -> core.Catalog_Song {
	youtube_song := song
	youtube_song.id = fmt.tprintf("%s%s", youtube.SONG_ID_PREFIX, song.youtube_id)
	youtube_song.youtube_id = ""
	youtube_song.is_lossless = false

	return youtube_song
}

// The song to play: Apple's when it has it, else the YouTube one.
to_playable :: proc(song: core.Catalog_Song) -> core.Catalog_Song {
	found, state := find_match(song)

	return found if state == .Found else song
}

// A YouTube song in a list is the queue's song when the queue plays Apple's match of it.
is_same_queue_song :: proc(queue_song, song: core.Catalog_Song) -> bool {
	return queue_song.id == song.id || queue_song.id == to_playable(song).id
}

// Holds the matcher's mutex. saved is the song as JSON, empty when Apple has none.
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

// Saves an answer, so the song is matched once. A found song is copied out of the answer it came in.
@(private)
save_found_match :: proc(video_id: string, song: core.Catalog_Song, is_found: bool) {
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
