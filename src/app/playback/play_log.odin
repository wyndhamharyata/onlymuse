package playback

import "core:strings"
import "om:app/core"
import "om:helper"
import "om:store"

// A song heard to its middle, or 4 minutes of a long one, is a play. One left sooner, after 2 s, is a skip.
PLAY_SHARE :: 0.5

play_log: [dynamic]store.Play

@(private = "file")
listening: struct {
	persistent_id:    string,
	song:             store.Play,
	duration_seconds: f64,
	furthest_seconds: f64,
}

start_play_log :: proc() {
	since := core.now_ms() - PLAY_LOG_DAYS * 86_400_000
	for play in store.list_plays(since) do append(&play_log, play)
}

// Once a frame: how far the playing song got, and a play or skip when it changes.
update_play_log :: proc() {
	now_playing := core.app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused
	persistent_id := now_playing.song.persistent_id if has_song else ""

	if persistent_id != listening.persistent_id {
		finish_listening()

		if persistent_id != "" {
			song := now_playing.song
			queue_song, is_queue_song := find_queue_song(persistent_id)

			listening.persistent_id = strings.clone(persistent_id)
			listening.duration_seconds = song.duration_seconds
			listening.song = {
				catalog_id = strings.clone(queue_song.id if is_queue_song else ""),
				name       = strings.clone(song.name),
				artist     = strings.clone(song.artist),
				album      = strings.clone(song.album),
			}
		}
	}

	if persistent_id != "" {
		position := helper.position_seconds(now_playing)

		listening.furthest_seconds = max(
			listening.furthest_seconds,
			min(position, listening.duration_seconds),
		)
	}
}

@(private = "file")
finish_listening :: proc() {
	if listening.persistent_id == "" do return

	furthest := listening.furthest_seconds
	needed := min(listening.duration_seconds * PLAY_SHARE, PLAY_MAX_SECONDS)
	is_play := listening.duration_seconds > 0 && furthest >= needed

	if is_play || furthest >= SKIP_MIN_SECONDS {
		play := listening.song
		play.is_skip = !is_play
		play.played_at = core.now_ms()
		store.save_play(play)
		// The log keeps the strings.
		append(&play_log, play)
	} else {
		delete(listening.song.catalog_id)
		delete(listening.song.name)
		delete(listening.song.artist)
		delete(listening.song.album)
	}

	delete(listening.persistent_id)
	listening = {}
}

// A logged play is the song's when its catalog ID matches, or its name and artist, as a song started in Music.app has no ID.
is_same_song :: proc(play: store.Play, song: core.Catalog_Song) -> bool {
	if play.catalog_id != "" && play.catalog_id == song.id do return true

	return play.name == song.name && play.artist == song.artist_name
}
