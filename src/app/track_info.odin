package app

import "core:fmt"
import "core:strings"
import "core:time"
import "om:apple"
import "om:helper"
import "om:platform"
import "om:store"
import "om:ui"

// What Music.app knows of a song and Apple's API does not. Dates are Unix ms, 0 when it has none.
Track_Info :: struct {
	is_in_library:   bool,
	favorited:       bool,
	played_count:    int,
	played_date_ms:  f64,
	skipped_count:   int,
	skipped_date_ms: f64,
	date_added_ms:   f64,
	bit_rate:        int,
	sample_rate:     int,
	kind:            string,
	bpm:             int,
	size:            f64,
}

// Music.app's answers, by persistent ID.
track_infos: map[string]Track_Info

// When each persistent ID was last asked about, so a page built every frame asks once a minute.
@(private = "file")
asked_at: map[string]f64

TRACK_INFO_REFRESH_MS :: 60_000

// The answer so far, asking Music.app when it has not been asked lately.
find_track_info :: proc(persistent_id: string) -> (Track_Info, bool) {
	if persistent_id == "" do return {}, false

	now := helper.now_ms()
	last, was_asked := asked_at[persistent_id]

	if !was_asked || now - last > TRACK_INFO_REFRESH_MS {
		if was_asked {
			asked_at[persistent_id] = now
		} else {
			asked_at[strings.clone(persistent_id)] = now
		}
		helper.request_track_info(persistent_id)
	}

	return track_infos[persistent_id]
}

apply_track_info :: proc(message: helper.Message) {
	if message.persistent_id == "" do return

	info := Track_Info {
		is_in_library   = message.is_in_library,
		favorited       = message.favorited,
		played_count    = message.played_count,
		played_date_ms  = message.played_date_ms,
		skipped_count   = message.skipped_count,
		skipped_date_ms = message.skipped_date_ms,
		date_added_ms   = message.date_added_ms,
		bit_rate        = message.bit_rate,
		sample_rate     = message.sample_rate,
		kind            = strings.clone(message.kind),
		bpm             = message.bpm,
		size            = message.size,
	}

	if old, ok := track_infos[message.persistent_id]; ok {
		delete(old.kind)
		track_infos[message.persistent_id] = info
	} else {
		track_infos[strings.clone(message.persistent_id)] = info
	}
}

// The song playing as the queue knows it, or as Music.app names it, with its persistent ID.
find_playing_song :: proc() -> (song: Catalog_Song, persistent_id: string, ok: bool) {
	shown, is_song := find_shown_song()
	if !is_song do return {}, "", false

	if queue_song, is_queue_song := find_queue_song(shown.persistent_id); is_queue_song do return queue_song, shown.persistent_id, true

	return {name = shown.name, artist_name = shown.artist, album_name = shown.album, duration_seconds = shown.duration_seconds}, shown.persistent_id, true
}

// ---- Favourites ----

// A toggle since the Favourite Songs playlist was last read, by catalog ID, so a row shows it at once.
@(private = "file")
favourite_changes: map[string]bool

@(private = "file")
Favourite_Request :: struct {
	catalog_id: string,
	favorited:  bool,
}

@(private = "file")
favourite_requests: map[int]Favourite_Request

@(private = "file")
favourite_set: struct {
	signature: int,
	ids:       map[string]bool,
}

// The catalog IDs in Favourite Songs, read again when its answers change.
@(private = "file")
favourite_ids :: proc() -> map[string]bool {
	_, playlist_id, _ := list_playlists()
	if playlist_id == "" do return favourite_set.ids

	bodies, signature, phase := watch_all_pages(fmt.tprintf("/v1/me/library/playlists/%s/tracks", playlist_id))
	if phase != .Ready || signature == favourite_set.signature do return favourite_set.ids

	for key in favourite_set.ids do delete(key)
	clear(&favourite_set.ids)
	favourite_set.signature = signature

	for body in bodies {
		for resource in apple.to_resources(body, context.temp_allocator) {
			song := apple.to_library_song(resource)
			if song.id not_in favourite_set.ids do favourite_set.ids[strings.clone(song.id)] = true
		}
	}

	return favourite_set.ids
}

// Music.app's answer for the playing song, else this session's toggle, else Favourite Songs.
is_favourite :: proc(song: Catalog_Song, persistent_id := "") -> bool {
	if persistent_id != "" {
		if info, ok := track_infos[persistent_id]; ok do return info.favorited
	}
	if changed, ok := favourite_changes[song.id]; ok do return changed

	return favourite_ids()[song.id]
}

toggle_favourite :: proc(song: Catalog_Song, persistent_id := "") {
	favorited := !is_favourite(song, persistent_id)
	set_favourite_change(song.id, favorited)

	if persistent_id != "" {
		if info, ok := &track_infos[persistent_id]; ok do info.favorited = favorited
	}

	request_id := helper.request_set_favorite(persistent_id, to_song_match(song), favorited)
	favourite_requests[request_id] = {strings.clone(song.id), favorited}
	show_toast("Added to Favourite Songs" if favorited else "Removed from Favourite Songs")
}

@(private = "file")
set_favourite_change :: proc(catalog_id: string, favorited: bool) {
	if catalog_id == "" do return

	if catalog_id in favourite_changes {
		favourite_changes[catalog_id] = favorited
	} else {
		favourite_changes[strings.clone(catalog_id)] = favorited
	}
}

// A song Music.app could not find, as one not in the library, keeps its old state.
apply_favourite_answer :: proc(message: helper.Message) {
	request, ok := favourite_requests[message.request_id]
	if !ok do return
	delete_key(&favourite_requests, message.request_id)
	defer delete(request.catalog_id)

	if message.persistent_id == "" {
		set_favourite_change(request.catalog_id, !request.favorited)
		show_toast("Music.app has no such song in your library. Add it to the library first.")
		return
	}

	// Favourite Songs follows Music.app a moment later.
	_, playlist_id, _ := list_playlists()
	if playlist_id != "" do apple.refresh(fmt.tprintf("/v1/me/library/playlists/%s/tracks?limit=100&offset=0", playlist_id))
}

// The heart on a row, the player bar and Now Playing. Returns true when clicked.
favourite_button :: proc(id: string, is_favourite: bool, size_points: f32 = 14) -> bool {
	return icon_button(id, "heart.fill" if is_favourite else "heart", size_points, app.accent if is_favourite else colors.faint)
}

// ---- The play log ----

// A song heard to its middle, or 4 minutes of a long one, is a play. One left sooner, after 2 s, is a skip.
PLAY_SHARE :: 0.5
PLAY_MAX_SECONDS :: 240
SKIP_MIN_SECONDS :: 2
// The log kept in memory, for shuffle and Now Playing.
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
	since := time.to_unix_nanoseconds(time.now()) / 1_000_000 - PLAY_LOG_DAYS * 86_400_000
	for play in store.list_plays(since) do append(&play_log, play)
}

// Once a frame: how far the playing song got, and a play or skip when it changes.
update_play_log :: proc() {
	now_playing := app.now_playing
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
		listening.furthest_seconds = max(listening.furthest_seconds, min(position, listening.duration_seconds))
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
		play.played_at = time.to_unix_nanoseconds(time.now()) / 1_000_000
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
is_same_song :: proc(play: store.Play, song: Catalog_Song) -> bool {
	if play.catalog_id != "" && play.catalog_id == song.id do return true

	return play.name == song.name && play.artist == song.artist_name
}

// ---- The toast ----

TOAST_SECONDS :: 2.5

@(private = "file")
toast: struct {
	text:     string,
	shown_at: time.Tick,
}

show_toast :: proc(text: string) {
	delete(toast.text)
	toast.text = strings.clone(text)
	toast.shown_at = time.tick_now()
}

// Over the page, just above the player bar, fading out at the end.
build_toast :: proc() {
	if toast.text == "" do return

	seconds := f32(time.duration_seconds(time.tick_since(toast.shown_at)))
	if seconds > TOAST_SECONDS {
		delete(toast.text)
		toast.text = ""
		return
	}

	opacity := min(1, (TOAST_SECONDS - seconds) / 0.3)
	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	width := measure_text(toast.text, 12.5) + 28
	ui.box("toast", {
		width         = ui.points(width),
		height        = ui.points(32),
		padding       = {14, 0, 14, 0},
		corner_radius = 10,
		background    = to_color(0x2c2c31ff),
		border_width  = 1,
		border_color  = to_color(0xffffff1c),
		text_color    = colors.text,
		font_size     = 12.5,
		fade          = 1 - opacity,
		position      = {(window_size.x - width) / 2, window_size.y - PLAYER_HEIGHT_POINTS - 44},
		flags         = {.Floating},
	}, toast.text)
	platform.request_frame()
}
