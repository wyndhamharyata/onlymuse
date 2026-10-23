package playback

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:apple"
import "om:console"
import "om:helper"
import "om:net"
import "om:platform"

ADD_POLL_SECONDS :: 1.5

ADD_TIMEOUT_SECONDS :: 45.0

@(private = "file")
Add_Job :: struct {
	catalog_id: string,
	play_count: int,
}

// Puts the song in the library on a thread of its own, then the queue polls Music.app for it.
@(private)
start_adding :: proc(catalog_id: string, play_count: int) {
	job := new(Add_Job)
	// The queue may free its song before the thread runs, so the job keeps its own copy of the ID.
	job^ = {strings.clone(catalog_id), play_count}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
			job := cast(^Add_Job)data
			defer net.stop_thread()
			defer free(job)
			defer delete(job.catalog_id)
			defer free_all(context.temp_allocator)

			status :=
				apple.post(fmt.tprintf("/v1/me/library?ids[songs]=%s", job.catalog_id)).status

			if status != 202 && status != 200 {
				console.add(
					"Queue",
					"Apple answered %s to adding a song to the library.",
					console.to_status_text(status),
				)
			}

			sync.guard(&queue_state.add_mutex)
			queue_state.added_play_count = job.play_count
			platform.wake()
		}, self_cleanup = true)
}

// A song matched from YouTube must start soon, or it goes back to YouTube.
@(private)
await_start :: proc() {
	if queue.songs[queue.index].youtube_id == "" do return

	queue_state.start_deadline_ms = helper.now_ms() + START_TIMEOUT_SECONDS * 1000
	platform.request_frame_after(START_TIMEOUT_SECONDS)
}

// Music.app could not play Apple's song, so the YouTube one plays, now and from now on.
// It returns false for a song with no YouTube one.
@(private)
fall_back_to_youtube :: proc() -> bool {
	queue_state.start_deadline_ms = 0

	song := queue.songs[queue.index]
	if song.youtube_id == "" do return false

	youtube_song := core.copy_song(matching.to_youtube_song(song))
	matching.reject_match(youtube_song)
	retire_song(queue.songs[queue.index])
	queue.songs[queue.index] = youtube_song

	kit.show_toast(
		fmt.tprintf("Apple Music could not play %s, so it plays from YouTube", youtube_song.name),
	)
	console.add(
		"Queue",
		"Music.app did not start %s within %.0f s, so it plays from YouTube from now on.",
		youtube_song.name,
		START_TIMEOUT_SECONDS,
	)

	play_at(queue.index)

	return true
}
