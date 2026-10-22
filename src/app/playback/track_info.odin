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

is_resume_shown :: proc() -> bool {
	now_playing := core.app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	return !has_song && queue.resume_point.song.persistent_id != ""
}

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
	signature:     int,
	ids:           map[string]bool,
	// app.frame_count + 1 of the frame that last checked the answers, so each row's heart and each song a
	// shuffle sorts reads them once a frame.
	checked_frame: int,
}

// The catalog IDs in Favourite Songs, read again when its answers change.
@(private = "file")
favourite_ids :: proc() -> map[string]bool {
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
	if persistent_id != "" {
		if info, ok := track_infos[persistent_id]; ok do return info.favorited
	}

	if changed, ok := favourite_changes[song.id]; ok do return changed
	if youtube.is_song_id(song.id) do return youtube_lists.is_youtube_favourite(song)

	return favourite_ids()[song.id]
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

	if persistent_id != "" {
		if info, ok := &track_infos[persistent_id]; ok do info.favorited = favorited
	}

	request_id := helper.request_set_favorite(persistent_id, to_song_match(song), favorited)
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

// A song Music.app could not find, as one not in the library, keeps its old state.
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
	if playlist_id != "" {
		apple.refresh(
			fmt.tprintf("/v1/me/library/playlists/%s/tracks?limit=100&offset=0", playlist_id),
		)
	}
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
