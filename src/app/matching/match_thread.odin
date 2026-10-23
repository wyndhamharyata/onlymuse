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

// Apple answers 429 for a while when an account searches too fast. One search runs at a time.
MATCH_GAP :: 300 * time.Millisecond

REFUSED_PAUSE :: 60 * time.Second

MAX_PAUSE_DOUBLING_COUNT :: 5

MAX_REFUSED_PAUSE :: 30 * time.Minute

FAILED_RETRY_PAUSE :: 60 * time.Second

MATCH_BATCH_COUNT :: 20

ALBUMS_PER_REQUEST_COUNT :: 20

MAX_FOUND_ALBUM_COUNT :: 3

@(private = "file")
albums: struct {
	found_ids: map[string][]string,
	songs:     map[string][]core.Catalog_Song,
}

@(private)
Match_Job :: struct {
	song:     core.Catalog_Song,
	video_id: string,
}

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

	for _ in thread.pool_pop_done(&matcher.pool) {}
	thread.pool_add_task(&matcher.pool, context.allocator, check_matches, nil)
}

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

	status := fetch_job_albums(jobs[:])

	for job in jobs {
		best: core.Catalog_Song
		is_found := false

		if status == 200 do best, is_found = find_in_albums(job.song)
		if status == 200 && !is_found do best, is_found, status = fetch_song_match(job.song)

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

	if status == 429 {
		is_pause_over := time.tick_diff(matcher.resume_at, time.tick_now()) >= 0

		if is_pause_over {
			matcher.refusal_count += 1
			doubling_count := min(matcher.refusal_count - 1, MAX_PAUSE_DOUBLING_COUNT)
			pause := min(
				REFUSED_PAUSE * time.Duration(1 << uint(doubling_count)),
				MAX_REFUSED_PAUSE,
			)
			matcher.resume_at = time.tick_add(time.tick_now(), pause)
		}

		matcher.failed[job.video_id] = matcher.resume_at
		return
	}

	if status != 200 {
		matcher.resume_at = time.tick_add(time.tick_now(), MATCH_GAP)
		matcher.failed[job.video_id] = time.tick_add(time.tick_now(), FAILED_RETRY_PAUSE)
		return
	}

	matcher.refusal_count = 0

	save_match_answer(job.video_id, best, is_found)
	delete(job.video_id)
}

@(private = "file")
fetch_job_albums :: proc(jobs: []^Match_Job) -> int {
	wanted := make([dynamic]string, context.temp_allocator)

	for job in jobs {
		if job.song.album_name == "" do continue

		key := to_album_key(job.song)
		ids, is_searched := albums.found_ids[key]

		if !is_searched {
			status: int
			ids, status = fetch_album_ids(job.song)
			if status != 200 do return status
			albums.found_ids[strings.clone(key)] = ids
		}

		for id in ids {
			is_wanted := id not_in albums.songs && !slice.contains(wanted[:], id)
			if is_wanted do append(&wanted, id)
		}
	}

	for first := 0; first < len(wanted); first += ALBUMS_PER_REQUEST_COUNT {
		end := min(first + ALBUMS_PER_REQUEST_COUNT, len(wanted))
		status := fetch_albums(wanted[first:end])
		if status != 200 do return status
	}

	return 200
}

@(private = "file")
fetch_album_ids :: proc(song: core.Catalog_Song) -> ([]string, int) {
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

	parsed: apple.Search_Answer
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

		for resource in apple.read_related(album, "tracks") {
			if resource.type == "songs" {
				append(&songs, core.copy_song(apple.to_catalog_song(resource)))
			}
		}

		if album.id not_in albums.songs do albums.songs[strings.clone(album.id)] = songs[:]
	}

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

@(private = "file")
fetch_song_match :: proc(song: core.Catalog_Song) -> (core.Catalog_Song, bool, int) {
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

@(private = "file")
find_best_match :: proc(song: core.Catalog_Song, body: string) -> (core.Catalog_Song, bool) {
	answer: apple.Search_Answer

	if json.unmarshal_string(body, &answer, allocator = context.temp_allocator) != nil {
		return {}, false
	}

	candidates := apple.to_catalog_songs(answer.results.songs.data, context.temp_allocator)

	return find_closest(song, candidates)
}
