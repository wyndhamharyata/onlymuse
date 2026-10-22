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

// Where Music.app was in the song it plays, as of its last post.
@(private)
Tracking :: struct {
	persistent_id:    string,
	duration_seconds: f64,
	position_seconds: f64,
	received_at_ms:   f64,
	is_playing:       bool,
}

// The song the helper starts when the one playing ends, and its place in the queue.
@(private)
Handoff :: struct {
	after_persistent_id: string,
	index:               int,
	persistent_id:       string,
}

// Tells the helper the queue's next song whenever the song playing or the next one changes.
@(private)
sync_handoff :: proc() {
	after := queue.playing_persistent_id
	repeat_index := queue.index if queue.repeat == "one" else find_next_index()
	next_index := repeat_index if after != "" else -1
	next_id := matching.to_playable(queue.songs[next_index]).id if next_index >= 0 else ""
	keeps_youtube := has_youtube_song_ahead()
	key := fmt.aprintf("%s|%d|%s|%v", after, next_index, next_id, keeps_youtube)

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

	request_id := helper.request_set_next(after if next_index >= 0 else "", match, keeps_youtube)
	queue_state.requests[request_id] = {kind = .Set_Next, handoff_version = queue_state.handoff_version, index = next_index, after = strings.clone(after)}
}

// The queue plays a YouTube song after this one, so the helper keeps its YouTube page open meanwhile.
@(private = "file")
has_youtube_song_ahead :: proc() -> bool {
	start := 0 if queue.repeat == "all" else queue.index + 1

	for song in queue.songs[max(start, 0):] {
		if youtube.is_song_id(matching.to_playable(song).id) do return true
	}

	return false
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
	now_playing := core.app.now_playing
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
		save_resume_point()
	}
	if is_queue_song && has_ended do play_next_after_end()
}

@(private = "file")
play_next_after_end :: proc() {
	next := queue.index if queue.repeat == "one" else find_next_index()

	if next >= 0 do play_at(next)
}

// Keeps the resume point on each post from Music.app, and every few seconds while a song plays.
@(private)
apply_resume_point :: proc() {
	now_playing := core.app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	if !has_song || !queue_state.has_tracking do return

	queue_state.last_resume_save = helper.now_ms()
	song := now_playing.song
	old := queue.resume_point.song
	queue.resume_point = {
		song             = {strings.clone(song.name), strings.clone(song.artist), strings.clone(song.album), strings.clone(song.persistent_id), song.duration_seconds, strings.clone(song.artwork_path)},
		position_seconds = to_estimate_seconds(queue_state.tracking, helper.now_ms()),
	}
	// This runs before the frame builds its boxes, so nothing shows the old text any more.
	delete(old.name)
	delete(old.artist)
	delete(old.album)
	delete(old.persistent_id)
	delete(old.artwork_path)
	save_resume_point()
}

@(private = "file")
restart_stalled_song :: proc(has_started: bool) {
	restart_count := queue_state.restart_count + 1
	song := queue.songs[queue.index]

	if has_started {
		console.add("Queue", "Music.app stopped at %s of %s and played on no further, so it starts the song again.", kit.to_clock_text(core.app.now_playing.position_seconds), song.name)
	} else {
		console.add("Queue", "Music.app had not started %s after %d s, so it starts the song again.", song.name, UNSTARTED_POSITION_COUNT * 2)
	}

	// Until Music.app's next post, its last position still reads as stopped.
	core.app.now_playing.stall_count = 0
	play_at(queue.index)
	queue_state.restart_count = restart_count
}

// Called each frame: starts polling once a song is added, and asks Music.app again when a poll is due.
update_queue :: proc() {
	added: int
	// sync.guard unlocks when its block ends, so these braces end the lock.
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

	now_playing := core.app.now_playing
	is_playing := now_playing.playback == .Playing
	has_stalled := is_playing && now_playing.has_started && now_playing.stall_count >= STALLED_POSITION_COUNT
	has_not_started := is_playing && !now_playing.has_started && now_playing.stall_count >= UNSTARTED_POSITION_COUNT
	can_restart := is_queue_leading() && queue_state.restart_count < MAX_RESTART_COUNT
	if (has_stalled || has_not_started) && can_restart do restart_stalled_song(now_playing.has_started)

	if queue_state.is_starting_youtube && core.app.now_playing.song.persistent_id == queue.playing_persistent_id {
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
	if core.app.now_playing.playback == .Playing && now - queue_state.last_resume_save > POSITION_SAVE_SECONDS * 1000 {
		apply_resume_point()
	}
}
