package app

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode"
import "om:apple"
import "om:platform"
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

// Two lengths this close are one recording. A remaster or a TV-size edit differs by more.
MATCH_SECONDS :: 3
// Apple refuses an account that searches too fast, with 429, for a while. So one search runs at a time, a
// little apart, and a refusal stops matching for a minute.
MATCH_GAP :: 300 * time.Millisecond
REFUSED_PAUSE :: 60 * time.Second
// Each refusal in a row doubles the pause, up to this.
MAX_REFUSED_PAUSE :: 30 * time.Minute
// The matching thread takes this many songs at a time, so it fetches the albums they name in one request.
MATCH_BATCH_COUNT :: 20
// Albums found for one YouTube album. A single and an album of the same name are both worth checking.
MAX_FOUND_ALBUM_COUNT :: 3
// Counts up whenever is_same_recording changes, so the matches saved under an older rule are made again.
// 3 drops the matches an index pointing into freed memory made from garbage.
MATCH_RULE_VERSION :: "3"

@(private = "file")
matcher: struct {
	mutex:      sync.Mutex,
	// By video ID.
	found:      map[string]Catalog_Song,
	missing:    map[string]bool,
	checking:   map[string]bool,
	// A song whose search got no answer, and when it may be checked again.
	failed:     map[string]time.Tick,
	// No search starts before this, after Apple refused one.
	resume_at:  time.Tick,
	refusal_count: int,
	// Songs waiting for the matching thread.
	pending:    [dynamic]^Match_Job,
	pool:       thread.Pool,
	is_started: bool,
	is_rule_checked: bool,
	// Counts up with each answer, so a page that counts matches reads them again.
	version:    int,
}

// Kept by the matching thread alone, so it needs no mutex.
@(private = "file")
albums: struct {
	// Apple's album IDs for a YouTube album, by to_album_key.
	found_ids: map[string][]string,
	// The songs of each album fetched, by Apple's album ID. Empty for an album Apple did not send.
	songs:     map[string][]Catalog_Song,
}

// The library's songs under each of their title keys, made again when the library changes. Main thread only.
// The library page's songs are read again into new memory whenever its phase changes, even with the same
// signature, so the index keeps copies of its own, in its arena.
@(private = "file")
library_index: struct {
	signature: int,
	is_built:  bool,
	arena:     virtual.Arena,
	by_title:  map[string][dynamic]Catalog_Song,
}

// The Apple Music song for a YouTube one. An Apple song is its own match. A song in the person's library
// matches with no request. Others wait for the library, then go to the matching thread.
find_match :: proc(song: Catalog_Song) -> (Catalog_Song, Match_State) {
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
find_library_match :: proc(song: Catalog_Song) -> (Catalog_Song, bool, apple.Phase) {
	songs, signature, phase := list_library_songs()
	if phase != .Ready do return {}, false, phase

	if !library_index.is_built || signature != library_index.signature {
		virtual.arena_destroy(&library_index.arena)
		library_index.by_title = {}
		_ = virtual.arena_init_growing(&library_index.arena)
		allocator := virtual.arena_allocator(&library_index.arena)
		library_index.by_title = make(map[string][dynamic]Catalog_Song, allocator)
		library_index.signature = signature
		library_index.is_built = true

		for library_song in songs {
			// A song uploaded from a Mac has no catalog ID, and Apple's catalog has nothing to say of it.
			if !is_catalog_id(library_song.id) do continue

			copied := copy_song(library_song, allocator)

			for key in list_title_keys(library_song.name) {
				if key not_in library_index.by_title do library_index.by_title[strings.clone(key, allocator)] = make([dynamic]Catalog_Song, allocator)
				append(&library_index.by_title[key], copied)
			}
		}
	}

	candidates := make([dynamic]Catalog_Song, context.temp_allocator)
	for key in list_title_keys(song.name) {
		if list, ok := library_index.by_title[key]; ok do append(&candidates, ..list[:])
	}
	best, is_found := find_closest(song, candidates[:])

	return best, is_found, .Ready
}

@(private = "file")
copy_song :: proc(song: Catalog_Song, allocator: mem.Allocator) -> Catalog_Song {
	copied := song
	copied.id = strings.clone(song.id, allocator)
	copied.name = strings.clone(song.name, allocator)
	copied.artist_name = strings.clone(song.artist_name, allocator)
	copied.album_name = strings.clone(song.album_name, allocator)
	copied.artwork.url = strings.clone(song.artwork.url, allocator)
	copied.artwork.bg_color = strings.clone(song.artwork.bg_color, allocator)
	copied.artwork.text_color1 = strings.clone(song.artwork.text_color1, allocator)

	return copied
}

@(private = "file")
find_match_locked :: proc(song: Catalog_Song, video_id: string) -> (Catalog_Song, Match_State) {
	if found, ok := matcher.found[video_id]; ok do return found, .Found

	return song, .Missing
}

// The person heard that Apple's song is another one, or Music.app could not play it. The YouTube song then
// always plays from YouTube.
reject_match :: proc(song: Catalog_Song) {
	video_id := youtube.to_video_id(song.id)
	if video_id == "" do return

	store.save_rejected_match(video_id)

	// The queue may hold a copy of Apple's song that shares its text, so the text stays.
	sync.guard(&matcher.mutex)
	delete_key(&matcher.found, video_id)
	if video_id not_in matcher.missing do matcher.missing[strings.clone(video_id)] = true
	matcher.version += 1
}

// Undoes reject_match. The song is checked against Apple's catalog again.
allow_match :: proc(song: Catalog_Song) {
	video_id := youtube.to_video_id(song.id)
	store.delete_rejected_match(video_id)

	sync.guard(&matcher.mutex)
	delete_key(&matcher.missing, video_id)
	matcher.version += 1
}

is_match_rejected :: proc(song: Catalog_Song) -> bool {
	video_id := youtube.to_video_id(song.id)

	return video_id != "" && store.is_match_rejected(video_id)
}

// The YouTube song an Apple match was made from, to play when Apple's will not. Its ID lives for the frame.
to_youtube_song :: proc(song: Catalog_Song) -> Catalog_Song {
	youtube_song := song
	youtube_song.id = fmt.tprintf("%s%s", youtube.SONG_ID_PREFIX, song.youtube_id)
	youtube_song.youtube_id = ""
	youtube_song.is_lossless = false

	return youtube_song
}

// The song to play: Apple's when it has it, else the YouTube one.
to_playable :: proc(song: Catalog_Song) -> Catalog_Song {
	found, state := find_match(song)

	return found if state == .Found else song
}

// A YouTube song in a list is the queue's song when the queue plays Apple's match of it.
is_same_queue_song :: proc(queue_song, song: Catalog_Song) -> bool {
	return queue_song.id == song.id || queue_song.id == to_playable(song).id
}

match_version :: proc() -> int {
	sync.guard(&matcher.mutex)

	return matcher.version
}

// Holds the matcher's mutex. saved is the song as JSON, empty when Apple has none.
@(private = "file")
keep_match :: proc(video_id, saved: string) {
	key := strings.clone(video_id)

	if saved == "" {
		matcher.missing[key] = true
		return
	}

	song: Catalog_Song
	if json.unmarshal_string(saved, &song) != nil {
		matcher.missing[key] = true
		return
	}
	song.youtube_id = key
	matcher.found[key] = song
}

// Saves an answer, so the song is matched once. A found song is copied out of the answer it came in.
@(private = "file")
save_found_match :: proc(video_id: string, song: Catalog_Song, is_found: bool) {
	saved := ""
	if is_found {
		bytes, _ := json.marshal(song, allocator = context.temp_allocator)
		saved = string(bytes)
	}
	store.save_match(video_id, saved)
	keep_match(video_id, saved)
}

@(private = "file")
Match_Job :: struct {
	song:     Catalog_Song,
	video_id: string,
}

// Holds the matcher's mutex.
@(private = "file")
start_matching :: proc(song: Catalog_Song, video_id: string) {
	if !matcher.is_started {
		thread.pool_init(&matcher.pool, context.allocator, 1)
		thread.pool_start(&matcher.pool)
		matcher.is_started = true
	}

	job := new(Match_Job)
	job^ = {clone_song(song), strings.clone(video_id)}
	matcher.checking[job.video_id] = true
	append(&matcher.pending, job)
	// Each task takes a batch, so a task that comes after its songs were taken finds none and ends.
	thread.pool_add_task(&matcher.pool, context.allocator, check_matches, nil)
}

// Runs on the one matching thread. The albums the batch names come first, as one album answers for each of its
// songs. A song no album answers for is searched alone. An answer that does not come is not saved, and its song
// is checked again later.
@(private = "file")
check_matches :: proc(task: thread.Task) {
	defer free_all(context.temp_allocator)

	jobs := make([dynamic]^Match_Job, context.temp_allocator)
	{
		sync.guard(&matcher.mutex)
		count := min(len(matcher.pending), MATCH_BATCH_COUNT)
		append(&jobs, ..matcher.pending[:count])
		remove_range(&matcher.pending, 0, count)
	}

	status := find_albums(jobs[:])

	for job in jobs {
		best: Catalog_Song
		is_found := false

		if status == 200 do best, is_found = find_in_albums(job.song)
		if status == 200 && !is_found do best, is_found, status = search_song(job.song)

		finish_job(job, best, is_found, status)
	}
}

@(private = "file")
finish_job :: proc(job: ^Match_Job, best: Catalog_Song, is_found: bool, status: int) {
	sync.guard(&matcher.mutex)
	delete_key(&matcher.checking, job.video_id)
	defer {
		delete_song(job.song)
		free(job)
		matcher.version += 1
		platform.wake()
	}

	// The rest of a batch fails with the same refusal, which counts once.
	if status == 429 {
		if time.tick_diff(matcher.resume_at, time.tick_now()) >= 0 {
			matcher.refusal_count += 1
			pause := min(REFUSED_PAUSE * time.Duration(1 << uint(min(matcher.refusal_count - 1, 5))), MAX_REFUSED_PAUSE)
			matcher.resume_at = time.tick_add(time.tick_now(), pause)
		}
		matcher.failed[job.video_id] = matcher.resume_at
		return
	}

	if status != 200 {
		matcher.resume_at = time.tick_add(time.tick_now(), MATCH_GAP)
		matcher.failed[job.video_id] = time.tick_add(time.tick_now(), REFUSED_PAUSE)
		return
	}

	matcher.refusal_count = 0

	save_found_match(job.video_id, best, is_found)
	delete(job.video_id)
}

// Searches Apple once for each album the jobs name, then fetches the albums found with their songs, 20 to a request.
@(private = "file")
find_albums :: proc(jobs: []^Match_Job) -> int {
	wanted := make([dynamic]string, context.temp_allocator)

	for job in jobs {
		if job.song.album_name == "" do continue

		key := to_album_key(job.song)
		ids, is_searched := albums.found_ids[key]

		if !is_searched {
			status: int
			ids, status = search_albums(job.song)
			if status != 200 do return status
			albums.found_ids[strings.clone(key)] = ids
		}

		for id in ids do if id not_in albums.songs && !slice.contains(wanted[:], id) do append(&wanted, id)
	}

	for first := 0; first < len(wanted); first += MATCH_BATCH_COUNT {
		status := fetch_albums(wanted[first:min(first + MATCH_BATCH_COUNT, len(wanted))])
		if status != 200 do return status
	}

	return 200
}

// Apple's albums with the YouTube album's name, by its artist.
@(private = "file")
search_albums :: proc(song: Catalog_Song) -> ([]string, int) {
	wait_to_search()

	term := fmt.tprintf("%s %s", to_plain_text(song.album_name), to_plain_text(song.artist_name))
	answer := apple.fetch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=albums&limit=10", apple.STOREFRONT, to_query_text(term)), context.temp_allocator)
	if answer.status != 200 do return nil, answer.status

	Search_Answer :: struct {
		results: struct {
			albums: apple.Related,
		},
	}
	parsed: Search_Answer
	_ = json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator)
	ids := make([dynamic]string)

	for album in parsed.results.albums.data {
		is_same_album := has_same_title(song.album_name, album.attributes.name) && is_same_artist(song.artist_name, album.attributes.artist_name)
		if is_same_album && len(ids) < MAX_FOUND_ALBUM_COUNT do append(&ids, strings.clone(album.id))
	}

	return ids[:], 200
}

@(private = "file")
fetch_albums :: proc(ids: []string) -> int {
	wait_to_search()

	path := fmt.tprintf("/v1/catalog/%s/albums?ids=%s&include=tracks", apple.STOREFRONT, strings.join(ids, ",", context.temp_allocator))
	answer := apple.fetch(path, context.temp_allocator)
	if answer.status != 200 do return answer.status

	for album in apple.to_resources(answer.body, context.temp_allocator) {
		songs := make([dynamic]Catalog_Song)
		for track in apple.list_related(album, "tracks") do if track.type == "songs" do append(&songs, clone_song(apple.to_catalog_song(track)))
		if album.id not_in albums.songs do albums.songs[strings.clone(album.id)] = songs[:]
	}

	// An album Apple did not send is not asked for again.
	for id in ids do if id not_in albums.songs do albums.songs[strings.clone(id)] = nil

	return 200
}

@(private = "file")
find_in_albums :: proc(song: Catalog_Song) -> (Catalog_Song, bool) {
	if song.album_name == "" do return {}, false

	candidates := make([dynamic]Catalog_Song, context.temp_allocator)
	for id in albums.found_ids[to_album_key(song)] or_else nil do append(&candidates, ..albums.songs[id] or_else nil)

	return find_closest(song, candidates[:])
}

// Apple's search for the song itself. When its album was not found, the album's name goes in the term too.
@(private = "file")
search_song :: proc(song: Catalog_Song) -> (Catalog_Song, bool, int) {
	has_album_ids := len(albums.found_ids[to_album_key(song)] or_else nil) > 0
	album_terms := make([dynamic]string, context.temp_allocator)
	if song.album_name != "" && !has_album_ids do append(&album_terms, song.album_name)
	append(&album_terms, "")

	for album in album_terms {
		wait_to_search()

		path := fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=10", apple.STOREFRONT, to_query_text(to_search_term(song, album)))
		answer := apple.fetch(path, context.temp_allocator)
		if answer.status != 200 do return {}, false, answer.status

		if best, is_found := find_best_match(song, answer.body); is_found do return best, true, 200
	}

	return {}, false, 200
}

@(private = "file")
to_album_key :: proc(song: Catalog_Song) -> string {
	return fmt.tprintf("%s|%s", to_match_key(song.album_name), to_match_key(song.artist_name))
}

// Sleeps until Apple may be asked again, then a little more.
@(private = "file")
wait_to_search :: proc() {
	resume_at: time.Tick
	{
		sync.guard(&matcher.mutex)
		resume_at = matcher.resume_at
	}

	if wait := time.tick_diff(time.tick_now(), resume_at); wait > 0 do time.sleep(wait)
	time.sleep(MATCH_GAP)
}

// The closest in length of Apple's songs that are the same song.
@(private = "file")
find_best_match :: proc(song: Catalog_Song, body: string) -> (Catalog_Song, bool) {
	Search_Answer :: struct {
		results: struct {
			songs: apple.Related,
		},
	}
	answer: Search_Answer
	if json.unmarshal_string(body, &answer, allocator = context.temp_allocator) != nil do return {}, false

	candidates := make([]Catalog_Song, len(answer.results.songs.data), context.temp_allocator)
	for resource, index in answer.results.songs.data do candidates[index] = apple.to_catalog_song(resource)

	return find_closest(song, candidates)
}

// The closest in length of the candidates that are the same recording.
@(private = "file")
find_closest :: proc(song: Catalog_Song, candidates: []Catalog_Song) -> (Catalog_Song, bool) {
	best: Catalog_Song
	is_found := false

	for candidate in candidates {
		if !is_same_recording(song, candidate) do continue

		is_closer := !is_found || abs(candidate.duration_seconds - song.duration_seconds) < abs(best.duration_seconds - song.duration_seconds)
		if is_closer do best = candidate
		is_found = true
	}

	return best, is_found
}

// The same title once cleaned, by the same artist, and about as long. YouTube often writes a Japanese
// title and its romaji as "追い風 - Oikaze", where Apple writes one of them, so either half matches. An
// artist named another way on each, such as in Japanese on one, is no match: the song plays from YouTube.
is_same_recording :: proc(youtube_song, apple_song: Catalog_Song) -> bool {
	has_lengths := youtube_song.duration_seconds > 0 && apple_song.duration_seconds > 0
	length_difference := abs(youtube_song.duration_seconds - apple_song.duration_seconds)

	if !has_same_title(youtube_song.name, apple_song.name) do return false
	if has_lengths && length_difference > MATCH_SECONDS do return false

	return is_same_artist(youtube_song.artist_name, apple_song.artist_name)
}

// "Ado" and "ADO" are one artist, and so are "SHE'S" and "SHE'S, Yuta Kanazawa".
@(private = "file")
is_same_artist :: proc(youtube_artist, apple_artist: string) -> bool {
	youtube_key := to_match_key(youtube_artist)
	apple_key := to_match_key(apple_artist)

	return youtube_key != "" && apple_key != "" && (strings.contains(apple_key, youtube_key) || strings.contains(youtube_key, apple_key))
}

@(private = "file")
has_same_title :: proc(youtube_name, apple_name: string) -> bool {
	apple_titles := list_title_keys(apple_name)

	for title in list_title_keys(youtube_name) {
		for apple_title in apple_titles do if title == apple_title do return true
	}

	return false
}

// The whole title and each half around " - " or " / ", as match keys.
@(private = "file")
list_title_keys :: proc(name: string) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	append(&keys, to_match_key(name))

	for separator in ([]string{" - ", " / ", "／"}) {
		if !strings.contains(name, separator) do continue
		for part in strings.split(name, separator, context.temp_allocator) do if key := to_match_key(part); key != "" do append(&keys, key)
	}

	return keys[:]
}

// Lowercase letters and digits only. Parts in brackets, such as "(Official Video)" or "【MV】", and
// "feat." with what follows are dropped. A name that is all brackets keeps them.
to_match_key :: proc(text: string) -> string {
	lower := strings.to_lower(text, context.temp_allocator)
	for marker in ([]string{" feat.", " feat ", " ft.", " (feat", " [feat"}) {
		if index := strings.index(lower, marker); index > 0 do lower = lower[:index]
	}

	key := to_letters(lower, true)

	return key if key != "" else to_letters(lower, false)
}

@(private = "file")
to_letters :: proc(text: string, skips_brackets: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		switch character {
		case '(', '[', '【', '『', '「', '（', '［':
			depth += 1
			continue
		case ')', ']', '】', '』', '」', '）', '］':
			depth = max(0, depth - 1)
			continue
		}

		is_kept := unicode.is_letter(character) || unicode.is_digit(character)
		if is_kept && (depth == 0 || !skips_brackets) do strings.write_rune(&builder, character)
	}

	return strings.to_string(builder)
}

// The title, the album and the artist without their bracketed parts. Apple's search finds nothing for a term
// with an apostrophe, such as "She's", so apostrophes go.
@(private = "file")
to_search_term :: proc(song: Catalog_Song, album: string) -> string {
	return fmt.tprintf("%s %s %s", to_plain_text(song.name), to_plain_text(album), to_plain_text(song.artist_name))
}

// The text without its bracketed parts and apostrophes. Text that is all brackets keeps them.
@(private = "file")
to_plain_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		switch character {
		case '(', '[', '【', '『', '「', '（', '［':
			depth += 1
		case ')', ']', '】', '』', '」', '）', '］':
			depth = max(0, depth - 1)
		case '\'', '’':
		case:
			if depth == 0 do strings.write_rune(&builder, character)
		}
	}

	plain := strings.trim_space(strings.to_string(builder))

	return plain if plain != "" else text
}
