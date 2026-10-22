package matching

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:app/core"
import "om:apple"
import "om:platform"

// Apple refuses an account that searches too fast, with 429, for a while. So one search runs at a time, a
// little apart. A refusal stops matching for a minute.
MATCH_GAP :: 300 * time.Millisecond

REFUSED_PAUSE :: 60 * time.Second

// Each refusal in a row doubles the pause, up to this.
MAX_REFUSED_PAUSE :: 30 * time.Minute

// The matching thread takes this many songs at a time, so it fetches the albums they name in one request.
MATCH_BATCH_COUNT :: 20

// Albums found for one YouTube album. A single and an album of the same name are both worth checking.
MAX_FOUND_ALBUM_COUNT :: 3

// Only the matching thread uses this, so it needs no mutex.
albums: struct {
	// Apple's album IDs for a YouTube album, by to_album_key.
	found_ids: map[string][]string,
	// The songs of each album fetched, by Apple's album ID. It is empty for an album that Apple did not send.
	songs:     map[string][]core.Catalog_Song,
}

@(private)
Match_Job :: struct {
	song:     core.Catalog_Song,
	video_id: string,
}

// The caller holds the matcher's mutex.
@(private)
start_matching :: proc(song: core.Catalog_Song, video_id: string) {
	if !matcher.is_started {
		thread.pool_init(&matcher.pool, context.allocator, 1)
		thread.pool_start(&matcher.pool)
		matcher.is_started = true
	}

	job := new(Match_Job)
	job^ = {core.copy_song(song), strings.clone(video_id)}
	matcher.checking[job.video_id] = true
	append(&matcher.pending, job)

	// Each task takes a batch, so a task that comes after another task took its songs finds none and ends.
	// The pool keeps each finished task until pool_pop_done takes it.
	for _ in thread.pool_pop_done(&matcher.pool) {}
	thread.pool_add_task(&matcher.pool, context.allocator, check_matches, nil)
}

// Runs on the one matching thread. The albums the batch names come first, as one album answers for each of its
// songs. It searches alone for a song that no album answers for. It saves nothing when an answer does not come.
// It then checks that song again later.
@(private = "file")
check_matches :: proc(task: thread.Task) {
	defer free_all(context.temp_allocator)

	jobs := make([dynamic]^Match_Job, context.temp_allocator)

	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&matcher.mutex)
		count := min(len(matcher.pending), MATCH_BATCH_COUNT)
		append(&jobs, ..matcher.pending[:count])
		remove_range(&matcher.pending, 0, count)
	}

	status := fetch_job_albums(jobs[:])

	for job in jobs {
		best: core.Catalog_Song
		is_found := false

		if status == 200 do best, is_found = find_in_albums(job.song)
		if status == 200 && !is_found do best, is_found, status = search_song(job.song)

		finish_job(job, best, is_found, status)
	}
}

@(private = "file")
finish_job :: proc(job: ^Match_Job, best: core.Catalog_Song, is_found: bool, status: int) {
	sync.guard(&matcher.mutex)
	delete_key(&matcher.checking, job.video_id)

	defer {
		core.delete_song(job.song)
		free(job)
		platform.wake()
	}

	// The rest of a batch fails with the same refusal, which counts once.
	if status == 429 {
		if time.tick_diff(matcher.resume_at, time.tick_now()) >= 0 {
			matcher.refusal_count += 1
			pause := min(
				REFUSED_PAUSE * time.Duration(1 << uint(min(matcher.refusal_count - 1, 5))),
				MAX_REFUSED_PAUSE,
			)
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
fetch_job_albums :: proc(jobs: []^Match_Job) -> int {
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

		for id in ids {
			if id not_in albums.songs && !slice.contains(wanted[:], id) {
				append(&wanted, id)
			}
		}
	}

	for first := 0; first < len(wanted); first += MATCH_BATCH_COUNT {
		status := fetch_albums(wanted[first:min(first + MATCH_BATCH_COUNT, len(wanted))])
		if status != 200 do return status
	}

	return 200
}

// Apple's albums with the YouTube album's name, by its artist.
@(private = "file")
search_albums :: proc(song: core.Catalog_Song) -> ([]string, int) {
	wait_to_search()

	term := fmt.tprintf("%s %s", to_plain_text(song.album_name), to_plain_text(song.artist_name))
	answer := apple.fetch(
		fmt.tprintf(
			"/v1/catalog/%s/search?term=%s&types=albums&limit=10",
			apple.STOREFRONT,
			apple.to_query_text(term),
		),
		context.temp_allocator,
	)
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
		is_same_album :=
			has_same_title(song.album_name, album.attributes.name) &&
			is_same_artist(song.artist_name, album.attributes.artist_name)

		if !is_same_album || len(ids) >= MAX_FOUND_ALBUM_COUNT do continue

		append(&ids, strings.clone(album.id))
	}

	return ids[:], 200
}

@(private = "file")
fetch_albums :: proc(ids: []string) -> int {
	wait_to_search()

	path := fmt.tprintf(
		"/v1/catalog/%s/albums?ids=%s&include=tracks",
		apple.STOREFRONT,
		strings.join(ids, ",", context.temp_allocator),
	)
	answer := apple.fetch(path, context.temp_allocator)
	if answer.status != 200 do return answer.status

	for album in apple.to_resources(answer.body, context.temp_allocator) {
		songs := make([dynamic]core.Catalog_Song)

		for track in apple.list_related(album, "tracks") {
			if track.type == "songs" {
				append(&songs, core.copy_song(apple.to_catalog_song(track)))
			}
		}

		if album.id not_in albums.songs do albums.songs[strings.clone(album.id)] = songs[:]
	}

	// A nil entry stops a second request for an album that Apple did not send.
	for id in ids do if id not_in albums.songs do albums.songs[strings.clone(id)] = nil

	return 200
}

@(private = "file")
find_in_albums :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, bool) {
	if song.album_name == "" do return {}, false

	candidates := make([dynamic]core.Catalog_Song, context.temp_allocator)

	for id in albums.found_ids[to_album_key(song)] or_else nil {
		append(&candidates, ..albums.songs[id] or_else nil)
	}

	return find_closest(song, candidates[:])
}

// Apple's search for the song itself. When the album search found no album, the album's name goes in the term too.
@(private = "file")
search_song :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, bool, int) {
	has_album_ids := len(albums.found_ids[to_album_key(song)] or_else nil) > 0
	album_terms := make([dynamic]string, context.temp_allocator)
	if song.album_name != "" && !has_album_ids do append(&album_terms, song.album_name)
	append(&album_terms, "")

	for album in album_terms {
		wait_to_search()

		path := fmt.tprintf(
			"/v1/catalog/%s/search?term=%s&types=songs&limit=10",
			apple.STOREFRONT,
			apple.to_query_text(to_search_term(song, album)),
		)
		answer := apple.fetch(path, context.temp_allocator)
		if answer.status != 200 do return {}, false, answer.status

		if best, is_found := find_best_match(song, answer.body); is_found do return best, true, 200
	}

	return {}, false, 200
}

@(private = "file")
to_album_key :: proc(song: core.Catalog_Song) -> string {
	return fmt.tprintf("%s|%s", to_match_key(song.album_name), to_match_key(song.artist_name))
}

// Sleeps until the matcher may ask Apple again, then a little more.
@(private = "file")
wait_to_search :: proc() {
	resume_at: time.Tick

	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&matcher.mutex)
		resume_at = matcher.resume_at
	}

	if wait := time.tick_diff(time.tick_now(), resume_at); wait > 0 do time.sleep(wait)
	time.sleep(MATCH_GAP)
}

// The closest in length of Apple's songs that are the same song.
@(private = "file")
find_best_match :: proc(song: core.Catalog_Song, body: string) -> (core.Catalog_Song, bool) {
	Search_Answer :: struct {
		results: struct {
			songs: apple.Related,
		},
	}
	answer: Search_Answer

	if json.unmarshal_string(body, &answer, allocator = context.temp_allocator) != nil {
		return {}, false
	}

	candidates := make([]core.Catalog_Song, len(answer.results.songs.data), context.temp_allocator)

	for resource, index in answer.results.songs.data {
		candidates[index] = apple.to_catalog_song(resource)
	}

	return find_closest(song, candidates)
}
