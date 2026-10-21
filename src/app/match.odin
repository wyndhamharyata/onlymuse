package app

import "core:encoding/json"
import "core:fmt"
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
// Counts up whenever is_same_recording changes, so the matches saved under an older rule are made again.
MATCH_RULE_VERSION :: "2"

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
	pool:       thread.Pool,
	is_started: bool,
	is_rule_checked: bool,
	// Counts up with each answer, so a page that counts matches reads them again.
	version:    int,
}

// The Apple Music song for a YouTube one. An Apple song is its own match.
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

	start_matching(song, video_id)

	return song, .Checking
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
	matcher.found[key] = song
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
	thread.pool_add_task(&matcher.pool, context.allocator, check_match, job)
}

// Runs on the one matching thread. A search that gets no answer is not saved, and the song is checked again later.
@(private = "file")
check_match :: proc(task: thread.Task) {
	job := cast(^Match_Job)task.data
	defer free_all(context.temp_allocator)

	wait_to_search()

	answer: apple.Answer
	best: Catalog_Song
	is_found := false

	// The album narrows the search, but a video has none, and a single's may differ.
	for album in ([]string{job.song.album_name, ""}) {
		path := fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=10", apple.STOREFRONT, to_query_text(to_search_term(job.song, album)))
		answer = apple.fetch(path, context.temp_allocator)
		best, is_found = find_best_match(job.song, answer.body)
		if is_found || answer.status != 200 do break

		wait_to_search()
	}

	sync.guard(&matcher.mutex)
	delete_key(&matcher.checking, job.video_id)
	defer {
		delete_song(job.song)
		free(job)
		matcher.version += 1
		platform.wake()
	}

	if answer.status != 200 {
		pause := REFUSED_PAUSE if answer.status == 429 else MATCH_GAP
		matcher.resume_at = time.tick_add(time.tick_now(), pause)
		matcher.failed[job.video_id] = time.tick_add(time.tick_now(), REFUSED_PAUSE)
		return
	}

	saved := ""
	if is_found {
		bytes, _ := json.marshal(best, allocator = context.temp_allocator)
		saved = string(bytes)
	}
	store.save_match(job.video_id, saved)
	keep_match(job.video_id, saved)
	delete(job.video_id)
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

	best: Catalog_Song
	is_found := false

	for resource in answer.results.songs.data {
		candidate := apple.to_catalog_song(resource)
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
	youtube_artist := to_match_key(youtube_song.artist_name)
	apple_artist := to_match_key(apple_song.artist_name)
	is_same_artist := youtube_artist != "" && apple_artist != "" && (strings.contains(apple_artist, youtube_artist) || strings.contains(youtube_artist, apple_artist))

	if !has_same_title(youtube_song.name, apple_song.name) do return false
	if has_lengths && length_difference > MATCH_SECONDS do return false

	return is_same_artist
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

// The title without its bracketed parts, the album and the artist. Apple's search finds nothing for a term
// with an apostrophe, such as "She's", so apostrophes go.
@(private = "file")
to_search_term :: proc(song: Catalog_Song, album: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in song.name {
		switch character {
		case '(', '[', '【', '『', '「', '（', '［':
			depth += 1
		case ')', ']', '】', '』', '」', '）', '］':
			depth = max(0, depth - 1)
		case:
			if depth == 0 do strings.write_rune(&builder, character)
		}
	}

	title := strings.trim_space(strings.to_string(builder))
	if title == "" do title = song.name

	term := fmt.tprintf("%s %s %s", title, album, song.artist_name)
	for apostrophe in ([]string{"'", "’"}) do term, _ = strings.remove_all(term, apostrophe, context.temp_allocator)

	return term
}
