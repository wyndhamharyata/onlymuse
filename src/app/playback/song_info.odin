package playback

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/youtube_lists"
import "om:apple"
import "om:helper"
import "om:youtube"

find_shown_song :: proc() -> (helper.Song, bool) {
	now_playing := core.app.now_playing

	if helper.has_song(now_playing) {
		return now_playing.song, true
	}

	resume := queue.resume_point

	return resume.song, resume.song.persistent_id != ""
}

is_resume_shown :: proc() -> bool {
	now_playing := core.app.now_playing
	has_song := helper.has_song(now_playing)

	return !has_song && queue.resume_point.song.persistent_id != ""
}

Song_Info :: struct {
	is_in_library:   bool,
	is_favourite:    bool,
	played_count:    int,
	played_date_ms:  f64,
	skipped_count:   int,
	skipped_date_ms: f64,
	date_added_ms:   f64,
	bit_rate_kbps:   int,
	sample_rate_hz:  int,
	kind:            string,
	bpm:             int,
	size_bytes:      f64,
}

song_infos: map[string]Song_Info

@(private = "file")
asked_at_ms: map[string]f64

SONG_INFO_REFRESH_MS :: 60_000

watch_song_info :: proc(persistent_id: string) -> Song_Info {
	if persistent_id == "" do return {}

	now_ms := helper.now_ms()
	last_asked_ms, was_asked := asked_at_ms[persistent_id]
	is_fresh := was_asked && now_ms - last_asked_ms <= SONG_INFO_REFRESH_MS

	if is_fresh do return song_infos[persistent_id]

	set_map_value(&asked_at_ms, persistent_id, now_ms)
	helper.send_song_info_request(persistent_id)

	return song_infos[persistent_id]
}

apply_song_info :: proc(message: helper.Message) {
	if message.persistent_id == "" do return

	info := Song_Info {
		is_in_library   = message.is_in_library,
		is_favourite    = message.is_favourite,
		played_count    = message.played_count,
		played_date_ms  = message.played_date_ms,
		skipped_count   = message.skipped_count,
		skipped_date_ms = message.skipped_date_ms,
		date_added_ms   = message.date_added_ms,
		bit_rate_kbps   = message.bit_rate_kbps,
		sample_rate_hz  = message.sample_rate_hz,
		kind            = strings.clone(message.kind),
		bpm             = message.bpm,
		size_bytes      = message.size_bytes,
	}

	if old, ok := song_infos[message.persistent_id]; ok do delete(old.kind)
	set_map_value(&song_infos, message.persistent_id, info)
}

@(private = "file")
set_map_value :: proc(values: ^map[string]$T, key: string, value: T) {
	key_pointer, value_pointer, is_new, _ := map_entry(values, key)
	if is_new do key_pointer^ = strings.clone(key)
	value_pointer^ = value
}

find_playing_song :: proc() -> (song: core.Catalog_Song, persistent_id: string, ok: bool) {
	shown, is_song := find_shown_song()
	if !is_song do return {}, "", false

	if queue_song, is_queue_song := find_queue_song(shown.persistent_id); is_queue_song {
		return queue_song, shown.persistent_id, true
	}

	return {
			name = shown.name,
			artist_name = shown.artist_name,
			album_name = shown.album_name,
			duration_seconds = shown.duration_seconds,
		},
		shown.persistent_id,
		true
}

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
	checked_frame: int,
}

@(private = "file")
watch_favourite_ids :: proc() -> map[string]bool {
	if favourite_set.checked_frame == core.app.frame_count + 1 do return favourite_set.ids

	favourite_set.checked_frame = core.app.frame_count + 1

	_, playlist_id, _ := core.watch_playlists()
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

is_favourite :: proc(song: core.Catalog_Song, persistent_id := "") -> bool {
	if info, ok := song_infos[persistent_id]; ok && persistent_id != "" do return info.is_favourite
	if changed, ok := favourite_changes[song.id]; ok do return changed
	if youtube.is_song_id(song.id) do return youtube_lists.is_youtube_favourite(song)

	return watch_favourite_ids()[song.id]
}

can_favourite :: proc(song: core.Catalog_Song) -> bool {
	return core.app.drives_music_app || youtube.is_song_id(song.id)
}

toggle_favourite :: proc(song: core.Catalog_Song, persistent_id: string) {
	if !can_favourite(song) do return

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
		info.is_favourite = favorited
	}

	request_id := helper.send_set_favorite(persistent_id, to_song_match(song), favorited)
	favourite_requests[request_id] = {strings.clone(song.id), favorited}
	kit.show_toast("Added to Favourite Songs" if favorited else "Removed from Favourite Songs")
}

@(private = "file")
set_favourite_change :: proc(catalog_id: string, favorited: bool) {
	if catalog_id == "" do return

	set_map_value(&favourite_changes, catalog_id, favorited)
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

	_, playlist_id, _ := core.watch_playlists()
	if playlist_id == "" do return

	apple.refresh(
		fmt.tprintf("/v1/me/library/playlists/%s/tracks?limit=100&offset=0", playlist_id),
	)
}

build_favourite_button :: proc(id: string, is_favourite: bool) -> bool {
	return kit.icon_button(
		id,
		"heart.circle.fill" if is_favourite else "heart.circle",
		13,
		core.app.accent if is_favourite else kit.colors.faint,
	)
}
