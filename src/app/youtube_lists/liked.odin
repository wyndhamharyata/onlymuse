package youtube_lists

import "core:strings"
import "core:thread"
import "om:app/core"
import "om:apple"
import "om:net"
import "om:youtube"

// Apple's Favourite Songs holds only Apple songs, so a YouTube song goes into onlymuse's own.
set_youtube_favourite :: proc(song: core.Catalog_Song, is_favourite: bool) {
	_, playlist_id, _ := core.watch_playlists()

	start_youtube_like(youtube.to_video_id(song.id), is_favourite)
	if playlist_id == "" do return

	if !is_favourite {
		remove_playlist_youtube_song(playlist_id, song.id)
	} else if !is_playlist_youtube_song(playlist_id, song.id) {
		add_playlist_youtube_songs(playlist_id, {{"", song}})
	}
}

is_youtube_favourite :: proc(song: core.Catalog_Song) -> bool {
	_, playlist_id, _ := core.watch_playlists()
	if playlist_id != "" && is_playlist_youtube_song(playlist_id, song.id) do return true

	return song.id in watch_youtube_liked_ids()
}

@(private = "file")
youtube_liked: struct {
	songs_address: rawptr,
	ids:           map[string]bool,
	checked_frame: int,
}

@(private = "file")
watch_youtube_liked_ids :: proc() -> map[string]bool {
	if !youtube.is_signed_in() do return nil
	if youtube_liked.checked_frame == core.app.frame_count + 1 do return youtube_liked.ids

	youtube_liked.checked_frame = core.app.frame_count + 1

	_, songs, phase := watch_youtube_songs(youtube.to_list_path(youtube.LIKED_ID))
	if phase != .Ready || raw_data(songs) == youtube_liked.songs_address do return youtube_liked.ids

	for key in youtube_liked.ids do delete(key)
	clear(&youtube_liked.ids)
	youtube_liked.songs_address = raw_data(songs)

	for song in songs {
		if song.id not_in youtube_liked.ids {
			youtube_liked.ids[strings.clone(song.id)] = true
		}
	}

	return youtube_liked.ids
}

@(private = "file")
Like_Job :: struct {
	video_id: string,
	is_liked: bool,
}

@(private = "file")
start_youtube_like :: proc(video_id: string, is_liked: bool) {
	if !youtube.is_signed_in() do return

	job := new(Like_Job)
	job^ = {strings.clone(video_id), is_liked}

	thread.create_and_start_with_data(job, proc(data: rawptr) {
			job := cast(^Like_Job)data
			defer net.stop_thread()
			defer free(job)
			defer delete(job.video_id)
			defer free_all(context.temp_allocator)

			if youtube.post_like(job.video_id, job.is_liked) != 200 do return

			apple.refresh(youtube.to_list_path(youtube.LIKED_ID))
		}, self_cleanup = true)
}
