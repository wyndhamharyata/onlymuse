package youtube_lists

import "core:strings"
import "core:thread"
import "om:app/core"
import "om:apple"
import "om:youtube"

// A YouTube song goes into Favourite Songs in onlymuse, as Apple's playlist holds Apple songs alone, and is
// liked on YouTube, so it lands in Liked Music and YouTube's mixes learn from it.
set_youtube_favourite :: proc(song: core.Catalog_Song, favorited: bool) {
	_, playlist_id, _ := core.list_playlists()

	if playlist_id != "" && favorited && !is_playlist_youtube_song(playlist_id, song.id) do add_playlist_youtube_songs(playlist_id, {{"", song}})
	if playlist_id != "" && !favorited do remove_playlist_youtube_song(playlist_id, song.id)

	start_youtube_like(youtube.to_video_id(song.id), favorited)
}

// In onlymuse's Favourite Songs, or liked on YouTube.
is_youtube_favourite :: proc(song: core.Catalog_Song) -> bool {
	_, playlist_id, _ := core.list_playlists()
	if playlist_id != "" && is_playlist_youtube_song(playlist_id, song.id) do return true

	return song.id in list_youtube_liked_ids()
}

// The song IDs in Liked Music, read again when its songs are. Signed out, none.
@(private = "file")
youtube_liked: struct {
	songs: rawptr,
	ids:   map[string]bool,
}

@(private = "file")
list_youtube_liked_ids :: proc() -> map[string]bool {
	if !youtube.is_signed_in() do return nil

	_, songs, phase := watch_youtube_songs(youtube.list_path(youtube.LIKED_ID))
	// The songs move to new memory each time they are read again, so their address says they changed.
	if phase != .Ready || raw_data(songs) == youtube_liked.songs do return youtube_liked.ids

	for key in youtube_liked.ids do delete(key)
	clear(&youtube_liked.ids)
	youtube_liked.songs = raw_data(songs)
	for song in songs do if song.id not_in youtube_liked.ids do youtube_liked.ids[strings.clone(song.id)] = true

	return youtube_liked.ids
}

@(private = "file")
Like_Job :: struct {
	video_id: string,
	is_liked: bool,
}

// On a thread of its own, as the request blocks. Liked Music is asked again after, so it shows the change.
@(private = "file")
start_youtube_like :: proc(video_id: string, is_liked: bool) {
	if !youtube.is_signed_in() do return

	job := new(Like_Job)
	job^ = {strings.clone(video_id), is_liked}
	thread.create_and_start_with_data(job, proc(data: rawptr) {
		job := cast(^Like_Job)data
		defer free(job)
		defer delete(job.video_id)
		defer free_all(context.temp_allocator)

		if youtube.send_like(job.video_id, job.is_liked) == 200 do apple.refresh(youtube.list_path(youtube.LIKED_ID))
	}, self_cleanup = true)
}
