package playback

import "core:encoding/json"
import "core:strings"
import "core:sync"
import "om:app/core"
import "om:app/matching"
import "om:console"
import "om:helper"
import "om:platform"
import "om:store"
import "om:youtube"

Resume_Point :: struct {
	song:             helper.Song,
	position_seconds: f64 `json:"positionSeconds"`,
}

// Music.app keeps no queue after a song that AppleScript starts, so the app plays each next song.
Queue_State :: struct {
	songs:                 []core.Catalog_Song,
	original_songs:        []core.Catalog_Song `json:"originalSongs"`,
	index:                 int,
	is_shuffled:           bool `json:"isShuffled"`,
	repeat:                string,
	is_adding:             bool `json:"isAdding"`,
	playing_persistent_id: string `json:"playingPersistentID"`,
	resume_point:          Resume_Point `json:"-"`,
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
	kind:            Request_Kind,
	play_count:      int,
	handoff_version: int,
	index:           int,
	after:           string,
	is_queue_song:   bool,
}

END_TOLERANCE_SECONDS :: 3.0

// Previous starts the song again past this point, as Music.app does.
RESTART_AFTER_SECONDS :: 3.0

// For a song with no file, Music.app shows a dialog and never starts it.
START_TIMEOUT_SECONDS :: 8.0

POSITION_POST_SECONDS :: 2

// Music.app can stop for good on a song new to the library. A second play starts it.
STALLED_POSITION_COUNT :: 2

// Music.app can take several seconds to load a song at 0:00, so it gets more still positions.
UNSTARTED_POSITION_COUNT :: 8

MAX_RESTART_COUNT :: 2

POSITION_SAVE_SECONDS :: 5.0

queue: Queue_State

@(private)
queue_state: struct {
	tracking:            Tracking,
	has_tracking:        bool,
	handoff:             Handoff,
	has_handoff:         bool,
	handoff_key:         string,
	handoff_version:     int,
	play_count:          int,
	requests:            map[int]Request,
	added_play_count:    int,
	add_mutex:           sync.Mutex,
	poll_deadline_ms:    f64,
	start_deadline_ms:   f64,
	is_starting_youtube: bool,
	restart_count:       int,
	next_poll_ms:        f64,
	is_polling:          bool,
	last_resume_save_ms: f64,
}

start_queue :: proc() {
	if text, ok := store.find_state("queue", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &queue)
	}

	if text, ok := store.find_state("resumePoint", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &queue.resume_point)
	}

	queue.is_adding = false
	if queue.repeat == "" do queue.repeat = "off"
	if queue.index >= len(queue.songs) do queue.index = len(queue.songs) - 1
}

@(private)
save_queue :: proc() {
	bytes, error := json.marshal(queue, allocator = context.temp_allocator)
	if error == nil do store.save_state("queue", string(bytes))
}

@(private)
save_resume_point :: proc() {
	bytes, error := json.marshal(queue.resume_point, allocator = context.temp_allocator)
	if error == nil do store.save_state("resumePoint", string(bytes))
}

@(private)
save_queue_and_handoff :: proc() {
	save_queue()
	send_handoff()
}

to_song_match :: proc(song: core.Catalog_Song) -> helper.Song_Match {
	return {
		name = song.name,
		artist_name = song.artist_name,
		album_name = song.album_name,
		duration_seconds = song.duration_seconds,
		youtube_id = youtube.to_video_id(song.id),
	}
}

@(private)
find_next_index :: proc() -> int {
	if queue.index + 1 < len(queue.songs) do return queue.index + 1
	if queue.repeat == "all" && len(queue.songs) > 0 do return 0

	return -1
}

play_queue_at :: proc(index: int) {
	queue_state.play_count += 1
	set_playable(index)
	queue.index = index
	start_matches()

	queue_state.is_polling = false
	queue_state.start_deadline_ms = 0
	queue_state.is_starting_youtube = false
	queue_state.restart_count = 0
	queue.is_adding = false
	set_playing_persistent_id("")
	save_queue_and_handoff()

	request_id := helper.send_play(to_song_match(queue.songs[index]))
	queue_state.requests[request_id] = {
		kind       = .Play,
		play_count = queue_state.play_count,
	}
}

@(private)
set_playing_persistent_id :: proc(persistent_id: string) {
	old := queue.playing_persistent_id
	queue.playing_persistent_id = strings.clone(persistent_id)
	delete(old)
}

apply_queue_answer :: proc(request_id: int, answered_id: string) {
	request, ok := queue_state.requests[request_id]
	if !ok do return

	delete_key(&queue_state.requests, request_id)

	is_current := request.play_count == queue_state.play_count

	switch request.kind {
	case .Set_Next:
		apply_set_next_answer(request, answered_id)
	case .Play:
		if is_current do apply_play_answer(answered_id)
	case .Poll:
		if is_current do apply_poll_answer(answered_id)
	case .Resume:
		apply_resume_answer(request, answered_id)
	}
}

@(private = "file")
apply_set_next_answer :: proc(request: Request, answered_id: string) {
	is_wanted :=
		request.handoff_version == queue_state.handoff_version &&
		request.after != "" &&
		request.index >= 0 &&
		answered_id != ""

	queue_state.has_handoff = is_wanted

	if !is_wanted {
		delete(request.after)
		return
	}

	delete(queue_state.handoff.after_persistent_id)
	delete(queue_state.handoff.persistent_id)
	queue_state.handoff = {request.after, request.index, strings.clone(answered_id)}
}

@(private = "file")
apply_play_answer :: proc(answered_id: string) {
	if answered_id != "" {
		set_playing_persistent_id(answered_id)
		queue_state.is_starting_youtube = youtube.is_song_id(answered_id)
		save_queue_and_handoff()
		set_start_deadline()
		return
	}

	// Music.app shows a song new to the library after a few seconds, about 6 s in NOTES.md.
	queue.is_adding = true
	save_queue_and_handoff()
	start_adding(queue.songs[queue.index].id, queue_state.play_count)
}

@(private = "file")
apply_poll_answer :: proc(answered_id: string) {
	is_poll_over := answered_id != "" || helper.now_ms() > queue_state.poll_deadline_ms

	if !is_poll_over {
		queue_state.next_poll_ms = helper.now_ms() + ADD_POLL_SECONDS * 1000
		platform.request_frame_after(ADD_POLL_SECONDS)
		return
	}

	if answered_id == "" {
		console.add(
			"Queue",
			"%s did not reach the library of Music.app.",
			queue.songs[queue.index].name,
		)
		if fall_back_to_youtube() do return
	}

	queue_state.is_polling = false
	queue.is_adding = false
	set_playing_persistent_id(answered_id)
	save_queue_and_handoff()
	if answered_id != "" do set_start_deadline()
}

@(private = "file")
apply_resume_answer :: proc(request: Request, answered_id: string) {
	if answered_id == "" do return

	if request.is_queue_song {
		set_playing_persistent_id(answered_id)
		save_queue_and_handoff()
	}

	helper.send_seek(queue.resume_point.position_seconds)
}

is_starting_youtube_song :: proc() -> bool {
	now_playing := core.app.now_playing
	is_loading :=
		now_playing.is_loading &&
		queue.index >= 0 &&
		now_playing.song.persistent_id == queue.playing_persistent_id

	return queue_state.is_starting_youtube || is_loading
}

find_queue_song :: proc(persistent_id: string) -> (core.Catalog_Song, bool) {
	is_current :=
		persistent_id != "" && persistent_id == queue.playing_persistent_id && queue.index >= 0

	return queue.songs[queue.index] if is_current else {}, is_current
}

is_current_song :: proc(song: core.Catalog_Song) -> bool {
	current, is_queue_song := find_queue_song(core.app.now_playing.song.persistent_id)

	return is_queue_song && matching.is_same_queue_song(current, song)
}

resume_last_song :: proc() {
	resume := queue.resume_point
	if resume.song.persistent_id == "" do return

	queue_state.play_count += 1

	is_queue_song := resume.song.persistent_id == queue.playing_persistent_id
	request_id := helper.send_play(
		{
			name = resume.song.name,
			artist_name = resume.song.artist_name,
			album_name = resume.song.album_name,
			duration_seconds = resume.song.duration_seconds,
			youtube_id = youtube.to_video_id(resume.song.persistent_id),
		},
	)
	queue_state.requests[request_id] = {
		kind          = .Resume,
		play_count    = queue_state.play_count,
		is_queue_song = is_queue_song,
	}
}
