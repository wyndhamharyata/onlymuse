// The queue, shuffle, the play log, favourites and what Music.app knows of each song.
// The package draws nothing but the menu of the shuffle rules.
package playback

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "om:app/core"
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
// The store saves this queue under the key "queue".
Queue_State :: struct {
	songs:                 []core.Catalog_Song,
	// The songs in the order they came, so shuffle can turn off again.
	original_songs:        []core.Catalog_Song `json:"originalSongs"`,
	index:                 int,
	is_shuffled:           bool `json:"isShuffled"`,
	repeat:                string,
	is_adding:             bool `json:"isAdding"`,
	// The ID is empty when the queue's song is not playing.
	playing_persistent_id: string `json:"playingPersistentID"`,
	// The last song Music.app played. The player shows it when Music.app stops. It changes every
	// few seconds, so json:"-" keeps it out of the save of the queue's thousands of songs.
	resume_point:          Resume_Point `json:"-"`,
}

// @(private = "file") hides a name from other files. @(private) hides it from other packages.
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
	// A number, not handoff_key, as sync_handoff frees the old key when a new one replaces it.
	handoff_version: int,
	index:           int,
	after:           string,
}

END_TOLERANCE_SECONDS :: 3.0

// Previous starts the song again past this point, as Music.app does.
RESTART_AFTER_SECONDS :: 3.0

// Music.app starts a library song within a second or two. For a song with no file, Music.app
// shows a dialog and never starts it.
START_TIMEOUT_SECONDS :: 8.0

// Music.app can play a song new to the library for a few seconds, then stop on it for good.
// After 2 still positions, about 4 s, the queue plays it again, as a switch away and back does.
STALLED_POSITION_COUNT :: 2

// Music.app can take several seconds to load a song at 0:00, so it gets 8 positions, about 16 s.
UNSTARTED_POSITION_COUNT :: 8

MAX_RESTART_COUNT :: 2

// The queue saves the position of the playing song this often, the most a force quit can lose.
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
	// It counts up with each play, so an older play that is still adding a song knows to stop.
	play_count:          int,
	requests:            map[int]Request,
	// The thread that adds a song to the library sets this to the play count it added for.
	added_play_count:    int,
	add_mutex:           sync.Mutex,
	poll_deadline_ms:    f64,
	// The time by which a song matched from YouTube must start. It is 0 when the queue awaits none.
	start_deadline_ms:   f64,
	// The YouTube page has the queue's song but did not start it yet.
	is_starting_youtube: bool,
	// How many times the queue started the playing song again after Music.app stopped on it.
	restart_count:       int,
	next_poll_ms:        f64,
	is_polling:          bool,
	last_resume_save_ms: f64,
}

start_queue :: proc() {
	// On the main thread, the memory of the temp allocator lasts until the next frame starts.
	if text, ok := store.find_state("queue", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &queue)
	}

	if text, ok := store.find_state("resumePoint", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &queue.resume_point)
	}

	// If the app quit while it added a song, that add is over now.
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
	sync_handoff()
}

to_song_match :: proc(song: core.Catalog_Song) -> helper.Song_Match {
	return {
		song.name,
		song.artist_name,
		song.album_name,
		song.duration_seconds,
		youtube.to_video_id(song.id),
	}
}

// Repeat all goes from the last song back to the first. It returns -1 when the queue is over.
@(private)
find_next_index :: proc() -> int {
	if queue.index + 1 < len(queue.songs) do return queue.index + 1
	if queue.repeat == "all" && len(queue.songs) > 0 do return 0

	return -1
}

// A YouTube song with a match plays from Apple Music. The match takes its place in the queue.
@(private)
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
	save_queue_and_handoff()

	request_id := helper.send_play(to_song_match(queue.songs[index]))
	queue_state.requests[request_id] = {
		kind       = .Play,
		play_count = queue_state.play_count,
	}
}

// Takes in the helper's answer to a playSong or setNext.
apply_queue_answer :: proc(request_id: int, answered_id: string) {
	request, ok := queue_state.requests[request_id]
	if !ok do return

	// The message lives for one frame. The queue keeps the ID.
	persistent_id := strings.clone(answered_id)

	delete_key(&queue_state.requests, request_id)

	is_current := request.play_count == queue_state.play_count

	switch request.kind {
	case .Set_Next:
		is_wanted :=
			request.handoff_version == queue_state.handoff_version &&
			request.after != "" &&
			request.index >= 0 &&
			persistent_id != ""
		if is_wanted do queue_state.handoff = {request.after, request.index, persistent_id}
		queue_state.has_handoff = is_wanted
	case .Play:
		if !is_current do return

		if persistent_id != "" {
			queue.playing_persistent_id = persistent_id
			queue_state.is_starting_youtube = youtube.is_song_id(persistent_id)
			save_queue_and_handoff()
			await_start()
			return
		}

		// Music.app shows a song new to the library after a few seconds, about 6 s in NOTES.md.
		queue.is_adding = true
		save_queue_and_handoff()
		start_adding(queue.songs[queue.index].id, queue_state.play_count)
	case .Poll:
		if !is_current do return

		is_polled := persistent_id != "" || helper.now_ms() > queue_state.poll_deadline_ms

		if !is_polled {
			queue_state.next_poll_ms = helper.now_ms() + ADD_POLL_SECONDS * 1000
			platform.request_frame_after(ADD_POLL_SECONDS)
			return
		}

		if persistent_id == "" {
			console.add(
				"Queue",
				"%s did not reach the library of Music.app.",
				queue.songs[queue.index].name,
			)
		}

		if persistent_id == "" && fall_back_to_youtube() do return

		queue_state.is_polling = false
		queue.is_adding = false
		queue.playing_persistent_id = persistent_id
		save_queue_and_handoff()
		if persistent_id != "" do await_start()
	case .Resume:
		if persistent_id == "" do return

		if request.after == "queue" {
			queue.playing_persistent_id = persistent_id
			save_queue_and_handoff()
		}

		// fmt writes {{ and }} as single braces.
		helper.send(
			fmt.tprintf(
				`{{"type":"seek","positionSeconds":%.3f}}`,
				queue.resume_point.position_seconds,
			),
		)
	}
}

// The YouTube page loads a song for some seconds before it plays. The player says so meanwhile.
is_starting_youtube_song :: proc() -> bool {
	now_playing := core.app.now_playing
	is_loading :=
		now_playing.is_loading &&
		queue.index >= 0 &&
		now_playing.song.persistent_id == queue.playing_persistent_id

	return queue_state.is_starting_youtube || is_loading
}

// The queue's song when it is the one playing, for its artwork and its lossless badge.
find_queue_song :: proc(persistent_id: string) -> (core.Catalog_Song, bool) {
	is_current :=
		persistent_id != "" && persistent_id == queue.playing_persistent_id && queue.index >= 0

	return queue.songs[queue.index] if is_current else {}, is_current
}

// Plays the last song again from where it was. Music.app may have quit or stopped since.
resume_last_song :: proc() {
	resume := queue.resume_point
	if resume.song.persistent_id == "" do return

	queue_state.play_count += 1

	is_queue_song := resume.song.persistent_id == queue.playing_persistent_id
	request_id := helper.send_play(
		{
			resume.song.name,
			resume.song.artist,
			resume.song.album,
			resume.song.duration_seconds,
			youtube.to_video_id(resume.song.persistent_id),
		},
	)
	queue_state.requests[request_id] = {
		kind       = .Resume,
		play_count = queue_state.play_count,
		after      = "queue" if is_queue_song else "",
	}
}
