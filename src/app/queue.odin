package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:console"
import "om:apple"
import "om:helper"
import "om:platform"
import "om:store"
import "om:youtube"

// The play queue. Music.app keeps no queue of its own after a song
// started by AppleScript, so the app plays each next song itself, and the helper hands off at each end.

Catalog_Song :: apple.Catalog_Song

Resume_Point :: struct {
	song:             helper.Song,
	position_seconds: f64 `json:"positionSeconds"`,
}

// The saved form, under the key "queue".
Queue_State :: struct {
	songs:                 []Catalog_Song,
	// The songs in the order they came, so shuffle can turn off again.
	original_songs:        []Catalog_Song `json:"originalSongs"`,
	index:                 int,
	is_shuffled:           bool `json:"isShuffled"`,
	repeat:                string,
	is_adding:             bool `json:"isAdding"`,
	// Empty when the queue's song is not playing.
	playing_persistent_id: string `json:"playingPersistentID"`,
	// The last song Music.app played and where it was. The player shows it when Music.app has stopped.
	// Its song's persistent ID is empty when there is none.
	resume_point:          Resume_Point `json:"resumePoint"`,
}

// Where Music.app was in the song it plays, as of its last post.
@(private = "file")
Tracking :: struct {
	persistent_id:    string,
	duration_seconds: f64,
	position_seconds: f64,
	received_at_ms:   f64,
	is_playing:       bool,
}

// The song the helper starts when the one playing ends, and its place in the queue.
@(private = "file")
Handoff :: struct {
	after_persistent_id: string,
	index:               int,
	persistent_id:       string,
}

@(private = "file")
Request_Kind :: enum {
	Play,
	Poll,
	Set_Next,
	Resume,
}

@(private = "file")
Request :: struct {
	kind:        Request_Kind,
	play_count:  int,
	handoff_key: string,
	index:       int,
	after:       string,
}

ADD_POLL_SECONDS :: 1.5
ADD_TIMEOUT_SECONDS :: 45.0
END_TOLERANCE_SECONDS :: 3.0
// Previous starts the song again past this point, as Music.app does.
RESTART_AFTER_SECONDS :: 3.0
// Music.app starts a library song within a second or two. One it has no file for shows a dialog and never starts.
START_TIMEOUT_SECONDS :: 8.0
// Music.app can play a song just added to the library for a few seconds, then wait on it for good. Two
// positions in a row that stand still, about 4 s, start the song again, as playing another song and back does.
STALLED_POSITION_COUNT :: 2
// A song at 0:00 may still be loading, which takes Music.app several seconds, so it gets about 16 s.
UNSTARTED_POSITION_COUNT :: 8
MAX_RESTART_COUNT :: 2
// While a song plays, its position is saved this often, so a force quit loses at most this much.
POSITION_SAVE_SECONDS :: 5.0

queue: Queue_State

@(private = "file")
queue_state: struct {
	tracking:          Tracking,
	has_tracking:      bool,
	handoff:           Handoff,
	has_handoff:       bool,
	handoff_key:       string,
	// Each new play counts up, so an older play that is still adding a song knows to stop.
	play_count:        int,
	requests:          map[int]Request,
	// Set by the thread that adds a song to the library, to the play count it added for.
	added_play_count:  int,
	add_mutex:         sync.Mutex,
	poll_deadline_ms:  f64,
	// When a song matched from YouTube must have started by. 0 when none is awaited.
	start_deadline_ms: f64,
	// The YouTube page has the queue's song and has not started it yet.
	is_starting_youtube: bool,
	// Times the song playing was started again after Music.app stopped on it.
	restart_count:     int,
	next_poll_ms:      f64,
	is_polling:        bool,
	last_resume_save:  f64,
}

start_queue :: proc() {
	if text, ok := store.find_state("queue", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &queue)
	}

	// A song that was being added when the app quit is not being added any more.
	queue.is_adding = false
	if queue.repeat == "" do queue.repeat = "off"
	if queue.index >= len(queue.songs) do queue.index = len(queue.songs) - 1
}

@(private = "file")
save_queue :: proc() {
	bytes, error := json.marshal(queue, allocator = context.temp_allocator)
	if error == nil do store.save_state("queue", string(bytes))
}

// Saves the queue and tells the helper its next song, as setState did.
@(private = "file")
set_queue :: proc() {
	save_queue()
	sync_handoff()
}

to_song_match :: proc(song: Catalog_Song) -> helper.Song_Match {
	return {song.name, song.artist_name, song.album_name, song.duration_seconds, youtube.to_video_id(song.id)}
}

// Repeat all goes from the last song back to the first. -1 when the queue is over.
@(private = "file")
find_next_index :: proc() -> int {
	if queue.index + 1 < len(queue.songs) do return queue.index + 1
	if queue.repeat == "all" && len(queue.songs) > 0 do return 0

	return -1
}

// Tells the helper the queue's next song whenever the song playing or the next one changes.
@(private = "file")
sync_handoff :: proc() {
	after := queue.playing_persistent_id
	repeat_index := queue.index if queue.repeat == "one" else find_next_index()
	next_index := repeat_index if after != "" else -1
	next_id := to_playable(queue.songs[next_index]).id if next_index >= 0 else ""
	key := fmt.aprintf("%s|%d|%s", after, next_index, next_id)

	if key == queue_state.handoff_key {
		delete(key)
		return
	}

	delete(queue_state.handoff_key)
	queue_state.handoff_key = key
	queue_state.has_handoff = false

	match: Maybe(helper.Song_Match)
	if next_index >= 0 {
		set_playable(next_index)
		match = to_song_match(queue.songs[next_index])
	}

	request_id := helper.request_set_next(after if next_index >= 0 else "", match)
	queue_state.requests[request_id] = {kind = .Set_Next, handoff_key = key, index = next_index, after = strings.clone(after)}
}

// A YouTube song whose Apple song is known plays from Apple Music, and takes its place in the queue.
@(private = "file")
play_at :: proc(index: int) {
	queue_state.play_count += 1
	queue_state.is_polling = false
	set_playable(index)
	queue.index = index
	queue_state.start_deadline_ms = 0
	queue_state.is_starting_youtube = false
	queue_state.restart_count = 0
	start_matches()
	queue.is_adding = false
	queue.playing_persistent_id = ""
	set_queue()

	request_id := helper.request_play(to_song_match(queue.songs[index]))
	queue_state.requests[request_id] = {kind = .Play, play_count = queue_state.play_count}
}

// Takes in the helper's answer to a playSong or setNext.
apply_queue_answer :: proc(request_id: int, answered_id: string) {
	request, ok := queue_state.requests[request_id]
	if !ok do return

	// The message lives for one frame, and the queue keeps the ID.
	persistent_id := strings.clone(answered_id)

	delete_key(&queue_state.requests, request_id)
	is_current := request.play_count == queue_state.play_count

	switch request.kind {
	case .Set_Next:
		is_wanted := request.handoff_key == queue_state.handoff_key && request.after != "" && request.index >= 0 && persistent_id != ""
		if is_wanted do queue_state.handoff = {request.after, request.index, persistent_id}
		queue_state.has_handoff = is_wanted
	case .Play:
		if !is_current do return
		if persistent_id != "" {
			queue.playing_persistent_id = persistent_id
			queue_state.is_starting_youtube = youtube.is_song_id(persistent_id)
			set_queue()
			await_start()
			return
		}

		// Music.app shows a song added to the library after a few seconds, about 6 in the tests.
		queue.is_adding = true
		set_queue()
		start_adding(queue.songs[queue.index].id, queue_state.play_count)
	case .Poll:
		if !is_current do return
		if persistent_id != "" || helper.now_ms() > queue_state.poll_deadline_ms {
			if persistent_id == "" do console.add("Queue", "%s did not reach the library of Music.app.", queue.songs[queue.index].name)
			if persistent_id == "" && fall_back_to_youtube() do return

			queue_state.is_polling = false
			queue.is_adding = false
			queue.playing_persistent_id = persistent_id
			set_queue()
			if persistent_id != "" do await_start()
			return
		}

		queue_state.next_poll_ms = helper.now_ms() + ADD_POLL_SECONDS * 1000
		platform.request_frame_after(ADD_POLL_SECONDS)
	case .Resume:
		if persistent_id == "" do return

		if request.after == "queue" {
			queue.playing_persistent_id = persistent_id
			set_queue()
		}
		helper.send(fmt.tprintf(`{{"type":"seek","positionSeconds":%.3f}}`, queue.resume_point.position_seconds))
	}
}

@(private = "file")
Add_Job :: struct {
	catalog_id: string,
	play_count: int,
}

// Puts the song in the library on a thread of its own, then the queue polls Music.app for it.
@(private = "file")
start_adding :: proc(catalog_id: string, play_count: int) {
	job := new(Add_Job)
	job^ = {catalog_id, play_count}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := cast(^Add_Job)data
		defer free(job)
		defer free_all(context.temp_allocator)

		status := apple.post(fmt.tprintf("/v1/me/library?ids[songs]=%s", job.catalog_id)).status
		if status != 202 && status != 200 do console.add("Queue", "Apple answered %s to adding a song to the library.", console.to_status_text(status))

		sync.guard(&queue_state.add_mutex)
		queue_state.added_play_count = job.play_count
		platform.wake()
	}, self_cleanup = true)
}

// A song matched from YouTube must start soon, or it goes back to YouTube.
@(private = "file")
await_start :: proc() {
	if queue.songs[queue.index].youtube_id == "" do return

	queue_state.start_deadline_ms = helper.now_ms() + START_TIMEOUT_SECONDS * 1000
	platform.request_frame_after(START_TIMEOUT_SECONDS)
}

// Music.app could not play Apple's song, so the YouTube one plays, now and from now on. False for a song with no YouTube one.
@(private = "file")
fall_back_to_youtube :: proc() -> bool {
	queue_state.start_deadline_ms = 0
	song := queue.songs[queue.index]
	if song.youtube_id == "" do return false

	youtube_song := clone_song(to_youtube_song(song))
	reject_match(youtube_song)
	delete_song(queue.songs[queue.index])
	queue.songs[queue.index] = youtube_song
	show_toast(fmt.tprintf("Apple Music could not play %s, so it plays from YouTube", youtube_song.name))
	console.add("Queue", "Music.app did not start %s within %.0f s, so it plays from YouTube from now on.", youtube_song.name, START_TIMEOUT_SECONDS)
	play_at(queue.index)

	return true
}

@(private = "file")
restart_stalled_song :: proc(has_started: bool) {
	restart_count := queue_state.restart_count + 1
	song := queue.songs[queue.index]

	if has_started {
		console.add("Queue", "Music.app stopped at %s of %s and played on no further, so it starts the song again.", to_clock_text(app.now_playing.position_seconds), song.name)
	} else {
		console.add("Queue", "Music.app had not started %s after %d s, so it starts the song again.", song.name, UNSTARTED_POSITION_COUNT * 2)
	}

	// Until Music.app's next post, its last position still reads as stopped.
	app.now_playing.stall_count = 0
	play_at(queue.index)
	queue_state.restart_count = restart_count
}

// Called each frame: starts polling once a song is added, and asks Music.app again when a poll is due.
update_queue :: proc() {
	added: int
	{
		sync.guard(&queue_state.add_mutex)
		added = queue_state.added_play_count
		queue_state.added_play_count = 0
	}

	now := helper.now_ms()

	if added != 0 && added == queue_state.play_count && queue.is_adding {
		queue_state.is_polling = true
		queue_state.poll_deadline_ms = now + ADD_TIMEOUT_SECONDS * 1000
		queue_state.next_poll_ms = now + ADD_POLL_SECONDS * 1000
		platform.request_frame_after(ADD_POLL_SECONDS)
	}

	if queue_state.is_polling && queue_state.next_poll_ms > 0 && now >= queue_state.next_poll_ms {
		queue_state.next_poll_ms = 0
		request_id := helper.request_play(to_song_match(queue.songs[queue.index]))
		queue_state.requests[request_id] = {kind = .Poll, play_count = queue_state.play_count}
	}

	now_playing := app.now_playing
	is_playing := now_playing.playback == .Playing
	has_stalled := is_playing && now_playing.has_started && now_playing.stall_count >= STALLED_POSITION_COUNT
	has_not_started := is_playing && !now_playing.has_started && now_playing.stall_count >= UNSTARTED_POSITION_COUNT
	can_restart := is_queue_leading() && queue_state.restart_count < MAX_RESTART_COUNT
	if (has_stalled || has_not_started) && can_restart do restart_stalled_song(now_playing.has_started)

	if queue_state.is_starting_youtube && app.now_playing.song.persistent_id == queue.playing_persistent_id {
		queue_state.is_starting_youtube = false
	}

	if queue_state.start_deadline_ms > 0 {
		has_song := now_playing.playback == .Playing || now_playing.playback == .Paused
		has_started := has_song && now_playing.song.persistent_id == queue.playing_persistent_id

		if has_started {
			queue_state.start_deadline_ms = 0
		} else if now >= queue_state.start_deadline_ms {
			fall_back_to_youtube()
		}
	}

	// The resume point, every few seconds while a song plays.
	if app.now_playing.playback == .Playing && now - queue_state.last_resume_save > POSITION_SAVE_SECONDS * 1000 {
		apply_resume_point()
	}
}

// The shuffle rules in shuffle.odin order it.
@(private = "file")
to_shuffled :: proc(songs: []Catalog_Song) -> []Catalog_Song {
	return shuffle_by_rules(songs)
}

// With shuffle on, the chosen song plays first and the others follow in a random order. The songs are copies.
@(private = "file")
to_play_order :: proc(songs: []Catalog_Song, first_index: int) -> []Catalog_Song {
	others := make([dynamic]Catalog_Song, context.temp_allocator)
	for song, index in songs do if index != first_index do append(&others, song)

	shuffled := to_shuffled(others[:])
	defer delete(shuffled)
	order := make([]Catalog_Song, len(songs))
	order[0] = clone_song(songs[first_index])
	for song, index in shuffled do order[index + 1] = clone_song(song)

	return order
}

// The queue owns its songs, text and all. A page's songs live in the page's memory, which is read again into
// new memory whenever its answers or its phase change, so a queue that pointed there would read freed memory.
@(private = "file")
replace_songs :: proc(songs, original_songs: []Catalog_Song) {
	delete_songs(queue.songs)
	delete_songs(queue.original_songs)
	queue.songs = songs
	queue.original_songs = original_songs
}

@(private = "file")
clone_songs :: proc(songs: []Catalog_Song) -> []Catalog_Song {
	cloned := make([]Catalog_Song, len(songs))
	for song, index in songs do cloned[index] = clone_song(song)

	return cloned
}

@(private = "file")
delete_songs :: proc(songs: []Catalog_Song) {
	for song in songs do delete_song(song)
	delete(songs)
}

// A YouTube song whose Apple song is known plays from Apple Music, and a copy of Apple's song takes its place.
@(private = "file")
set_playable :: proc(index: int) {
	playable := to_playable(queue.songs[index])
	if playable.id == queue.songs[index].id do return

	cloned := clone_song(playable)
	delete_song(queue.songs[index])
	queue.songs[index] = cloned
}

// The queue's next YouTube songs are checked against Apple's catalog now, so they play from Apple when their
// turn comes. Each later one is checked when it is next.
MATCHED_AHEAD_COUNT :: 25

@(private = "file")
start_matches :: proc() {
	if queue.index < 0 do return

	ahead := queue.songs[queue.index:min(len(queue.songs), queue.index + MATCHED_AHEAD_COUNT)]
	for song in ahead do if youtube.is_song_id(song.id) do find_match(song)
}

play_songs :: proc(songs: []Catalog_Song, index: int) {
	if len(songs) == 0 do return

	if !queue.is_shuffled {
		replace_songs(clone_songs(songs), clone_songs(songs))
		play_at(index)
		return
	}

	replace_songs(to_play_order(songs, index), clone_songs(songs))
	play_at(0)
}

shuffle_songs :: proc(songs: []Catalog_Song) {
	if len(songs) == 0 do return

	shuffled := to_shuffled(songs)
	defer delete(shuffled)

	replace_songs(clone_songs(shuffled), clone_songs(songs))
	queue.is_shuffled = true
	play_at(0)
}

// Puts the song right after the one playing. With nothing queued, it plays now. The queue takes song, a copy.
play_next :: proc(song: Catalog_Song) {
	if queue.index < 0 || len(queue.songs) == 0 {
		play_songs([]Catalog_Song{song}, 0)
		return
	}

	after := queue.index + 1
	songs := make([]Catalog_Song, len(queue.songs) + 1)
	copy(songs[:after], queue.songs[:after])
	songs[after] = song
	copy(songs[after + 1:], queue.songs[after:])

	original := make([]Catalog_Song, len(queue.original_songs) + 1)
	copy(original, queue.original_songs)
	original[len(original) - 1] = clone_song(song)

	// The new lists hold the old songs themselves, so only the old lists go.
	delete(queue.songs)
	delete(queue.original_songs)
	queue.songs = songs
	queue.original_songs = original
	sync_handoff()
	save_queue()
}

play_queue_at :: proc(index: int) {
	play_at(index)
}

remove_from_queue :: proc(index: int) {
	if index == queue.index do return

	removed_id := strings.clone(queue.songs[index].id, context.temp_allocator)
	delete_song(queue.songs[index])
	ordered_remove_slice(&queue.songs, index)

	for song, original_index in queue.original_songs {
		if song.id != removed_id do continue

		delete_song(song)
		ordered_remove_slice(&queue.original_songs, original_index)
		break
	}

	if index < queue.index do queue.index -= 1
	set_queue()
}

@(private = "file")
ordered_remove_slice :: proc(songs: ^[]Catalog_Song, index: int) {
	copy(songs[index:], songs[index + 1:])
	songs^ = songs[:len(songs) - 1]
}

toggle_shuffle :: proc() {
	if queue.index < 0 || queue.index >= len(queue.songs) {
		queue.is_shuffled = !queue.is_shuffled
		set_queue()
		return
	}

	current_id := strings.clone(queue.songs[queue.index].id, context.temp_allocator)

	if queue.is_shuffled {
		queue.is_shuffled = false
		delete_songs(queue.songs)
		queue.songs = clone_songs(queue.original_songs)
		queue.index = 0
		for song, index in queue.songs do if song.id == current_id do queue.index = index
		set_queue()
		return
	}

	original_index := 0
	for song, index in queue.original_songs do if song.id == current_id do original_index = index

	delete_songs(queue.songs)
	queue.songs = to_play_order(queue.original_songs, original_index)
	queue.index = 0
	queue.is_shuffled = true
	set_queue()
}

cycle_repeat :: proc() {
	switch queue.repeat {
	case "off":
		queue.repeat = "all"
	case "all":
		queue.repeat = "one"
	case:
		queue.repeat = "off"
	}
	set_queue()
}

// The queue leads only while Music.app plays the song it started. Otherwise Music.app's own order applies.
@(private = "file")
is_queue_leading :: proc() -> bool {
	now_playing := app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused
	playing_id := now_playing.song.persistent_id if has_song else ""

	return queue.is_adding || (playing_id != "" && playing_id == queue.playing_persistent_id)
}

skip_to_next :: proc() {
	if !is_queue_leading() {
		helper.send(`{"type":"next"}`)
		return
	}

	if next := find_next_index(); next >= 0 do play_at(next)
}

skip_to_previous :: proc(position_seconds: f64) {
	if !is_queue_leading() {
		helper.send(`{"type":"previous"}`)
		return
	}

	if position_seconds > RESTART_AFTER_SECONDS || queue.index == 0 {
		helper.send(`{"type":"seek","positionSeconds":0}`)
		return
	}

	play_at(queue.index - 1)
}

// The YouTube page loads a song for some seconds before it plays, and the player says so meanwhile.
is_starting_youtube_song :: proc() -> bool {
	return queue_state.is_starting_youtube
}

// The queue's song when it is the one playing, for its artwork and its lossless badge.
find_queue_song :: proc(persistent_id: string) -> (Catalog_Song, bool) {
	is_current := persistent_id != "" && persistent_id == queue.playing_persistent_id && queue.index >= 0

	return queue.songs[queue.index] if is_current else {}, is_current
}

@(private = "file")
to_estimate_seconds :: proc(current: Tracking, now_ms: f64) -> f64 {
	if !current.is_playing do return current.position_seconds

	return current.position_seconds + (now_ms - current.received_at_ms) / 1000
}

// The helper's handoff, when this post shows its song starting. With repeat one it starts the same song from 0.
@(private = "file")
find_handoff :: proc(now_playing: helper.Now_Playing, was_at_end: bool) -> bool {
	persistent_id := now_playing.song.persistent_id
	tracking := queue_state.tracking
	is_same_song := queue_state.has_tracking && tracking.persistent_id == persistent_id
	is_restart := is_same_song && was_at_end && now_playing.position_seconds < END_TOLERANCE_SECONDS
	handoff := queue_state.handoff

	if !queue_state.has_handoff || persistent_id != handoff.persistent_id do return false
	if queue.playing_persistent_id != handoff.after_persistent_id do return false
	if !queue_state.has_tracking || tracking.persistent_id != handoff.after_persistent_id do return false

	return !is_same_song || is_restart
}

@(private = "file")
apply_playing_song :: proc(now_playing: helper.Now_Playing, now_ms: f64) {
	tracking := queue_state.tracking
	has_tracking := queue_state.has_tracking
	is_same_song := has_tracking && tracking.persistent_id == now_playing.song.persistent_id
	was_at_end := has_tracking && to_estimate_seconds(tracking, now_ms) >= tracking.duration_seconds - END_TOLERANCE_SECONDS
	is_handed_off := find_handoff(now_playing, was_at_end)
	is_queue_song := has_tracking && tracking.persistent_id == queue.playing_persistent_id
	has_queue_song_ended := !is_handed_off && !is_same_song && is_queue_song && was_at_end
	estimate_seconds := to_estimate_seconds(tracking, now_ms) if is_same_song else 0
	is_paused := now_playing.playback == .Paused

	delete(queue_state.tracking.persistent_id)
	queue_state.tracking = {
		persistent_id    = fmt.aprint(now_playing.song.persistent_id),
		duration_seconds = now_playing.song.duration_seconds,
		position_seconds = max(now_playing.position_seconds, estimate_seconds) if is_paused else now_playing.position_seconds,
		received_at_ms   = now_playing.position_read_at_ms,
		is_playing       = !is_paused,
	}
	queue_state.has_tracking = true

	// The helper started the queue's next song itself, so the queue only moves on.
	if is_handed_off {
		handoff := queue_state.handoff
		queue_state.play_count += 1
		queue_state.has_handoff = false
		delete(queue_state.handoff_key)
		queue_state.handoff_key = ""
		queue.index = handoff.index
		queue_state.start_deadline_ms = 0
		queue.is_adding = false
		queue.playing_persistent_id = handoff.persistent_id
		set_queue()
	}

	// Music.app's Autoplay can go on to a song of its own with no Stopped, so a switch at the end is the end.
	if has_queue_song_ended do play_next_after_end()
}

// At a song's end Music.app posts Paused, then Stopped. The paused position it posts may be 0.
apply_queue_now_playing :: proc() {
	now_playing := app.now_playing
	now_ms := helper.now_ms()

	if now_playing.playback == .Playing || now_playing.playback == .Paused {
		apply_playing_song(now_playing, now_ms)
		apply_resume_point()
		return
	}

	finished := queue_state.tracking
	has_finished := queue_state.has_tracking
	is_queue_song := has_finished && finished.persistent_id == queue.playing_persistent_id
	has_ended := has_finished && to_estimate_seconds(finished, now_ms) >= finished.duration_seconds - END_TOLERANCE_SECONDS

	queue_state.has_tracking = false
	if has_ended && queue.resume_point.song.persistent_id != "" {
		queue.resume_point.position_seconds = 0
		save_queue()
	}
	if is_queue_song && has_ended do play_next_after_end()
}

@(private = "file")
play_next_after_end :: proc() {
	next := queue.index if queue.repeat == "one" else find_next_index()

	if next >= 0 do play_at(next)
}

// Keeps the resume point on each post from Music.app, and every few seconds while a song plays.
@(private = "file")
apply_resume_point :: proc() {
	now_playing := app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	if !has_song || !queue_state.has_tracking do return

	queue_state.last_resume_save = helper.now_ms()
	song := now_playing.song
	queue.resume_point = {
		song             = {fmt.aprint(song.name), fmt.aprint(song.artist), fmt.aprint(song.album), fmt.aprint(song.persistent_id), song.duration_seconds, fmt.aprint(song.artwork_path)},
		position_seconds = to_estimate_seconds(queue_state.tracking, helper.now_ms()),
	}
	save_queue()
}

// Plays the last song again from where it was. Music.app may have quit or stopped since.
resume_last_song :: proc() {
	resume := queue.resume_point
	if resume.song.persistent_id == "" do return

	queue_state.play_count += 1
	is_queue_song := resume.song.persistent_id == queue.playing_persistent_id
	request_id := helper.request_play({resume.song.name, resume.song.artist, resume.song.album, resume.song.duration_seconds, youtube.to_video_id(resume.song.persistent_id)})
	queue_state.requests[request_id] = {kind = .Resume, play_count = queue_state.play_count, after = "queue" if is_queue_song else ""}
}
