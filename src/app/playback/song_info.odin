package playback

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/youtube_lists"
import "om:apple"
import "om:helper"
import "om:youtube"

// With Music.app stopped or closed, the player shows the last song, paused where it was.
find_shown_song :: proc() -> (helper.Song, bool) {
	now_playing := core.app.now_playing

	if now_playing.playback == .Playing || now_playing.playback == .Paused {
		return now_playing.song, true
	}

	resume := queue.resume_point

	return resume.song, resume.song.persistent_id != ""
}

// Whether the player shows the last song, paused where it was, as Music.app plays nothing.
is_resume_shown :: proc() -> bool {
	now_playing := core.app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	return !has_song && queue.resume_point.song.persistent_id != ""
}

// What Music.app knows of a song and Apple's API does not. Dates are Unix ms, 0 when it has none.
Song_Info :: struct {
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
song_infos: map[string]Song_Info

// When the app last asked Music.app about each persistent ID, so a page that builds every frame
// asks once a minute.
@(private = "file")
asked_at_ms: map[string]f64

SONG_INFO_REFRESH_MS :: 60_000

// The answer so far. It asks Music.app when the app did not ask within SONG_INFO_REFRESH_MS.
watch_song_info :: proc(persistent_id: string) -> (Song_Info, bool) {
	if persistent_id == "" do return {}, false

	now_ms := helper.now_ms()
	last_asked_ms, was_asked := asked_at_ms[persistent_id]
	is_fresh := was_asked && now_ms - last_asked_ms <= SONG_INFO_REFRESH_MS

	if is_fresh do return song_infos[persistent_id]

	if was_asked {
		asked_at_ms[persistent_id] = now_ms
	} else {
		asked_at_ms[strings.clone(persistent_id)] = now_ms
	}

	helper.send_song_info_request(persistent_id)

	return song_infos[persistent_id]
}

apply_track_info :: proc(message: helper.Message) {
	if message.persistent_id == "" do return

	info := Song_Info {
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

	if old, ok := song_infos[message.persistent_id]; ok {
		delete(old.kind)
		song_infos[message.persistent_id] = info
	} else {
		song_infos[strings.clone(message.persistent_id)] = info
	}
}

// The song playing as the queue knows it, or as Music.app names it, with its persistent ID.
find_playing_song :: proc() -> (song: core.Catalog_Song, persistent_id: string, ok: bool) {
	shown, is_song := find_shown_song()
	if !is_song do return {}, "", false

	if queue_song, is_queue_song := find_queue_song(shown.persistent_id); is_queue_song {
		return queue_song, shown.persistent_id, true
	}

	return {
			name = shown.name,
			artist_name = shown.artist,
			album_name = shown.album,
			duration_seconds = shown.duration_seconds,
		},
		shown.persistent_id,
		true
}

// Each toggle since the app last read Favourite Songs, by catalog ID, so a row shows it at once.
@(private = "file")
favourite_changes: map[string]bool

// A favourite toggle sent to the helper, kept until Music.app answers it.
@(private = "file")
Favourite_Request :: struct {
	catalog_id: string,
	favorited:  bool,
}

@(private = "file")
favourite_requests: map[int]Favourite_Request

@(private = "file")
favourite_set: struct {
	signature:     int,
	ids:           map[string]bool,
	// frame_count + 1 of the last check of the answers, so 0 means no check yet. One check a frame
	// serves each heart on a row and each song that a shuffle sorts.
	checked_frame: int,
}

// The catalog IDs in Favourite Songs, read again when its answers change.
@(private = "file")
watch_favourite_ids :: proc() -> map[string]bool {
	if favourite_set.checked_frame == core.app.frame_count + 1 do return favourite_set.ids

	favourite_set.checked_frame = core.app.frame_count + 1

	_, playlist_id, _ := core.list_playlists()
	if playlist_id == "" do return favourite_set.ids

	bodies, signature, phase := core.watch_all_pages(
		fmt.tprintf("/v1/me/library/playlists/%s/tracks", playlist_id),
	)
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
is_favourite :: proc(song: core.Catalog_Song, persistent_id := "") -> bool {
	if info, ok := song_infos[persistent_id]; ok && persistent_id != "" do return info.favorited
	if changed, ok := favourite_changes[song.id]; ok do return changed
	if youtube.is_song_id(song.id) do return youtube_lists.is_youtube_favourite(song)

	return watch_favourite_ids()[song.id]
}

toggle_favourite :: proc(song: core.Catalog_Song, persistent_id := "") {
	favorited := !is_favourite(song, persistent_id)
	set_favourite_change(song.id, favorited)

	if youtube.is_song_id(song.id) {
		youtube_lists.set_youtube_favourite(song, favorited)
		kit.show_toast(
			"Added to Favourite Songs and liked on YouTube" if favorited else "Removed from Favourite Songs and unliked on YouTube",
		)
		return
	}

	if info, ok := &song_infos[persistent_id]; ok && persistent_id != "" {
		info.favorited = favorited
	}

	request_id := helper.send_set_favorite(persistent_id, to_song_match(song), favorited)
	favourite_requests[request_id] = {strings.clone(song.id), favorited}
	kit.show_toast("Added to Favourite Songs" if favorited else "Removed from Favourite Songs")
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

// A song Music.app could not find, such as one not in the library, keeps its old favourite state.
apply_favourite_answer :: proc(message: helper.Message) {
	request, ok := favourite_requests[message.request_id]
	if !ok do return

	delete_key(&favourite_requests, message.request_id)
	defer delete(request.catalog_id)

	if message.persistent_id == "" {
		set_favourite_change(request.catalog_id, !request.favorited)
		kit.show_toast("Music.app has no such song in your library. Add it to the library first.")
		return
	}

	// Favourite Songs follows Music.app a moment later.
	_, playlist_id, _ := core.list_playlists()
	if playlist_id == "" do return

	apple.refresh(
		fmt.tprintf("/v1/me/library/playlists/%s/tracks?limit=100&offset=0", playlist_id),
	)
}

// The heart on a row, the player bar and Now Playing. Returns true when clicked.
favourite_button :: proc(id: string, is_favourite: bool, size_points: f32 = 14) -> bool {
	return kit.icon_button(
		id,
		"heart.circle.fill" if is_favourite else "heart.circle",
		size_points,
		core.app.accent if is_favourite else kit.colors.faint,
	)
}

PLAY_MAX_SECONDS :: 240

SKIP_MIN_SECONDS :: 2

// The log kept in memory, for shuffle and Now Playing.
PLAY_LOG_DAYS :: 120
