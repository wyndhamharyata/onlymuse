package playback

import "core:fmt"
import "core:strings"
import "core:sync"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:console"
import "om:helper"
import "om:platform"
import "om:youtube"

@(private)
Tracking :: struct {
	persistent_id:    string,
	duration_seconds: f64,
	position_seconds: f64,
	received_at_ms:   f64,
	is_playing:       bool,
}

@(private)
Handoff :: struct {
	after_persistent_id: string,
	index:               int,
	persistent_id:       string,
}

@(private)
send_handoff :: proc() {
	after := queue.playing_persistent_id
	next_index := find_index_after_end() if after != "" else -1
	next_id := matching.watch_playable(queue.songs[next_index]).id if next_index >= 0 else ""
	has_youtube_ahead := has_youtube_song_ahead()
	key := fmt.aprintf("%s|%d|%s|%v", after, next_index, next_id, has_youtube_ahead)

	if key == queue_state.handoff_key {
		delete(key)
		return
	}

	delete(queue_state.handoff_key)
	queue_state.handoff_key = key
	queue_state.handoff_version += 1
	queue_state.has_handoff = false

	match: Maybe(helper.Song_Match)

	if next_index >= 0 {
		set_playable(next_index)
		match = to_song_match(queue.songs[next_index])
	}

	request_id := helper.send_set_next(after if next_index >= 0 else "", match, has_youtube_ahead)
	queue_state.requests[request_id] = {
		kind            = .Set_Next,
		handoff_version = queue_state.handoff_version,
		index           = next_index,
		after           = strings.clone(after),
	}
}

@(private = "file")
find_index_after_end :: proc() -> int {
	return queue.index if queue.repeat == "one" else find_next_index()
}

@(private = "file")
has_youtube_song_ahead :: proc() -> bool {
	start := 0 if queue.repeat == "all" else queue.index + 1

	for song in queue.songs[max(start, 0):] {
		if youtube.is_song_id(matching.watch_playable(song).id) do return true
	}

	return false
}

@(private = "file")
to_estimate_seconds :: proc(current: Tracking, now_ms: f64) -> f64 {
	if !current.is_playing do return current.position_seconds

	return current.position_seconds + (now_ms - current.received_at_ms) / 1000
}

@(private = "file")
is_tracking_at_end :: proc(now_ms: f64) -> bool {
	tracking := queue_state.tracking
	end_seconds := tracking.duration_seconds - END_TOLERANCE_SECONDS

	return queue_state.has_tracking && to_estimate_seconds(tracking, now_ms) >= end_seconds
}

@(private = "file")
is_handoff_starting :: proc(now_playing: helper.Now_Playing, was_at_end: bool) -> bool {
	persistent_id := now_playing.song.persistent_id
	tracking := queue_state.tracking
	handoff := queue_state.handoff
	is_tracked_song := queue_state.has_tracking && tracking.persistent_id == persistent_id
	is_restart :=
		is_tracked_song && was_at_end && now_playing.position_seconds < END_TOLERANCE_SECONDS
	is_handoff_song := queue_state.has_handoff && persistent_id == handoff.persistent_id
	is_after_queue_song :=
		queue_state.has_tracking &&
		tracking.persistent_id == handoff.after_persistent_id &&
		queue.playing_persistent_id == handoff.after_persistent_id

	if !is_handoff_song || !is_after_queue_song do return false

	return !is_tracked_song || is_restart
}

@(private = "file")
apply_playing_song :: proc(now_playing: helper.Now_Playing, now_ms: f64) {
	tracking := queue_state.tracking
	has_tracking := queue_state.has_tracking
	is_tracked_song := has_tracking && tracking.persistent_id == now_playing.song.persistent_id
	was_at_end := is_tracking_at_end(now_ms)
	is_handed_off := is_handoff_starting(now_playing, was_at_end)
	is_queue_song := has_tracking && tracking.persistent_id == queue.playing_persistent_id
	has_queue_song_ended := !is_handed_off && !is_tracked_song && is_queue_song && was_at_end
	estimate_seconds := to_estimate_seconds(tracking, now_ms) if is_tracked_song else 0
	is_paused := now_playing.playback == .Paused

	delete(queue_state.tracking.persistent_id)
	// Music.app may post Paused at 0 at a song's end, so a pause keeps the larger position.
	queue_state.tracking = {
		persistent_id    = fmt.aprint(now_playing.song.persistent_id),
		duration_seconds = now_playing.song.duration_seconds,
		position_seconds = max(now_playing.position_seconds, estimate_seconds) if is_paused else now_playing.position_seconds,
		received_at_ms   = now_playing.position_read_at_ms,
		is_playing       = !is_paused,
	}
	queue_state.has_tracking = true

	if is_handed_off {
		handoff := queue_state.handoff

		queue_state.play_count += 1
		queue_state.has_handoff = false
		delete(queue_state.handoff_key)
		queue_state.handoff_key = ""
		queue.index = handoff.index
		queue_state.start_deadline_ms = 0
		queue.is_adding = false
		set_playing_persistent_id(handoff.persistent_id)
		save_queue_and_handoff()
	}

	// Autoplay in Music.app can switch songs with no Stopped post, so a switch at the end ends it.
	if has_queue_song_ended do play_next_after_end()
}

apply_queue_now_playing :: proc() {
	now_playing := core.app.now_playing
	now_ms := helper.now_ms()

	if helper.has_song(now_playing) {
		apply_playing_song(now_playing, now_ms)
		apply_resume_point()
		return
	}

	finished := queue_state.tracking
	was_tracking := queue_state.has_tracking
	is_queue_song := was_tracking && finished.persistent_id == queue.playing_persistent_id
	has_ended := is_tracking_at_end(now_ms)

	queue_state.has_tracking = false

	if has_ended && queue.resume_point.song.persistent_id != "" {
		queue.resume_point.position_seconds = 0
		save_resume_point()
	}

	if is_queue_song && has_ended do play_next_after_end()
}

@(private = "file")
play_next_after_end :: proc() {
	next := find_index_after_end()

	if next >= 0 do play_queue_at(next)
}

@(private)
apply_resume_point :: proc() {
	now_playing := core.app.now_playing
	has_song := helper.has_song(now_playing)

	if !has_song || !queue_state.has_tracking do return

	queue_state.last_resume_save_ms = helper.now_ms()

	song := now_playing.song
	old := queue.resume_point.song

	queue.resume_point = {
		song             = {
			strings.clone(song.name),
			strings.clone(song.artist_name),
			strings.clone(song.album_name),
			strings.clone(song.persistent_id),
			song.duration_seconds,
			strings.clone(song.artwork_path),
		},
		position_seconds = to_estimate_seconds(queue_state.tracking, helper.now_ms()),
	}

	delete(old.name)
	delete(old.artist_name)
	delete(old.album_name)
	delete(old.persistent_id)
	delete(old.artwork_path)

	save_resume_point()
}

// Music.app can say it plays while its position stays still. The queue then starts the song again.
@(private = "file")
restart_stalled_song :: proc(now_playing: helper.Now_Playing) {
	is_playing := now_playing.playback == .Playing
	has_started := now_playing.has_started
	has_stalled := is_playing && has_started && now_playing.stall_count >= STALLED_POSITION_COUNT
	has_not_started :=
		is_playing && !has_started && now_playing.stall_count >= UNSTARTED_POSITION_COUNT
	can_restart := is_queue_leading() && queue_state.restart_count < MAX_RESTART_COUNT
	is_restart_due := (has_stalled || has_not_started) && can_restart
	restart_count := queue_state.restart_count + 1

	if !is_restart_due do return

	song := queue.songs[queue.index]

	if has_started {
		console.add(
			"Queue",
			"Music.app stopped at %s of %s, so the queue starts the song again.",
			kit.to_clock_text(now_playing.position_seconds),
			song.name,
		)
	} else {
		console.add(
			"Queue",
			"Music.app did not start %s within %d s, so the queue starts it again.",
			song.name,
			UNSTARTED_POSITION_COUNT * POSITION_POST_SECONDS,
		)
	}

	core.app.now_playing.stall_count = 0
	play_queue_at(queue.index)
	queue_state.restart_count = restart_count
}

@(private = "file")
apply_added_song :: proc(now_ms: f64) {
	added_play_count: int

	{
		sync.guard(&queue_state.add_mutex)
		added_play_count = queue_state.added_play_count
		queue_state.added_play_count = 0
	}

	is_added_for_play :=
		added_play_count != 0 && added_play_count == queue_state.play_count && queue.is_adding
	if !is_added_for_play do return

	queue_state.is_polling = true
	queue_state.poll_deadline_ms = now_ms + ADD_TIMEOUT_SECONDS * 1000
	queue_state.next_poll_ms = now_ms + ADD_POLL_SECONDS * 1000
	platform.request_frame_after(ADD_POLL_SECONDS)
}

@(private = "file")
send_due_poll :: proc(now_ms: f64) {
	is_poll_due :=
		queue_state.is_polling &&
		queue_state.next_poll_ms > 0 &&
		now_ms >= queue_state.next_poll_ms
	if !is_poll_due do return

	queue_state.next_poll_ms = 0
	request_id := helper.send_play(to_song_match(queue.songs[queue.index]))
	queue_state.requests[request_id] = {
		kind       = .Poll,
		play_count = queue_state.play_count,
	}
}

@(private = "file")
apply_start_deadline :: proc(now_playing: helper.Now_Playing, now_ms: f64) {
	has_queue_song_id := now_playing.song.persistent_id == queue.playing_persistent_id
	is_queue_song_playing := helper.has_song(now_playing) && has_queue_song_id
	is_start_late := queue_state.start_deadline_ms > 0 && now_ms >= queue_state.start_deadline_ms

	if has_queue_song_id do queue_state.is_starting_youtube = false

	if is_queue_song_playing {
		queue_state.start_deadline_ms = 0
	} else if is_start_late {
		fall_back_to_youtube()
	}
}

update_queue :: proc() {
	now_playing := core.app.now_playing
	now_ms := helper.now_ms()
	is_save_due := now_ms - queue_state.last_resume_save_ms > POSITION_SAVE_SECONDS * 1000

	apply_added_song(now_ms)
	send_due_poll(now_ms)
	restart_stalled_song(now_playing)
	apply_start_deadline(now_playing, now_ms)

	if now_playing.playback == .Playing && is_save_due do apply_resume_point()
}
