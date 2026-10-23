package playback

import "core:strings"
import "om:app/core"
import "om:helper"
import "om:store"

PLAY_SHARE :: 0.5

PLAY_MAX_SECONDS :: 240

SKIP_MIN_SECONDS :: 2

PLAY_LOG_DAYS :: 120

play_log: [dynamic]store.Play

@(private = "file")
listening: struct {
	persistent_id:    string,
	song:             store.Play,
	duration_seconds: f64,
	furthest_seconds: f64,
}

start_play_log :: proc() {
	since_ms := core.now_ms() - PLAY_LOG_DAYS * core.DAY_MS
	for play in store.list_plays(since_ms) do append(&play_log, play)
}

apply_now_playing_to_play_log :: proc() {
	now_playing := core.app.now_playing
	has_song := helper.has_song(now_playing)
	persistent_id := now_playing.song.persistent_id if has_song else ""
	position_seconds := helper.read_position_seconds(now_playing)
	is_restart :=
		persistent_id == listening.persistent_id &&
		position_seconds < SKIP_MIN_SECONDS &&
		is_heard_as_play()
	is_new_song := persistent_id != listening.persistent_id || is_restart

	if is_new_song do finish_listening()
	if persistent_id == "" do return

	if is_new_song {
		song := now_playing.song
		queue_song, is_queue_song := find_queue_song(persistent_id)

		listening.persistent_id = strings.clone(persistent_id)
		listening.duration_seconds = song.duration_seconds
		listening.song = {
			catalog_id = strings.clone(queue_song.id if is_queue_song else ""),
			name       = strings.clone(song.name),
			artist     = strings.clone(song.artist_name),
			album      = strings.clone(song.album_name),
		}
	}

	listening.furthest_seconds = max(
		listening.furthest_seconds,
		min(position_seconds, listening.duration_seconds),
	)
}

@(private = "file")
finish_listening :: proc() {
	if listening.persistent_id == "" do return

	is_play := is_heard_as_play()
	is_logged := is_play || listening.furthest_seconds >= SKIP_MIN_SECONDS

	if is_logged {
		play := listening.song
		play.is_skip = !is_play
		play.played_at_ms = core.now_ms()
		store.save_play(play)
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

@(private = "file")
is_heard_as_play :: proc() -> bool {
	needed_seconds := min(listening.duration_seconds * PLAY_SHARE, PLAY_MAX_SECONDS)

	return listening.duration_seconds > 0 && listening.furthest_seconds >= needed_seconds
}

is_same_song :: proc(play: store.Play, song: core.Catalog_Song) -> bool {
	if play.catalog_id != "" && play.catalog_id == song.id do return true

	return play.name == song.name && play.artist == song.artist_name
}
