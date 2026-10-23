package menus

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:app/youtube_lists"
import "om:apple"
import "om:net"
import "om:platform"
import "om:youtube"

@(private = "file")
Write_Job :: struct {
	path, body:             string,
	done_text, failed_text: string,
	refresh_path:           string,
}

@(private = "file")
Created_Playlist :: struct {
	id, name, done_text: string,
	youtube_songs:       []youtube_lists.Playlist_YouTube_Song,
	should_open_page:    bool,
}

@(private = "file")
write_results: struct {
	mutex:   sync.Mutex,
	toasts:  [dynamic]string,
	refresh: [dynamic]string,
	created: [dynamic]Created_Playlist,
}

@(private = "file")
start_write :: proc(job: Write_Job) {
	copied := new(Write_Job)
	copied^ = {
		strings.clone(job.path),
		strings.clone(job.body),
		strings.clone(job.done_text),
		strings.clone(job.failed_text),
		strings.clone(job.refresh_path),
	}

	thread.create_and_start_with_data(copied, run_write, self_cleanup = true)
}

@(private = "file")
run_write :: proc(data: rawptr) {
	job := cast(^Write_Job)data
	defer net.stop_thread()
	status := apple.post(job.path, job.body).status
	is_done := is_success_status(status)
	toast := strings.clone(job.done_text) if is_done else to_failure_text(job.failed_text, status)

	{
		sync.guard(&write_results.mutex)
		append(&write_results.toasts, toast)

		if is_done do append(&write_results.refresh, strings.clone(job.refresh_path))
	}
	platform.wake()

	delete(job.path)
	delete(job.body)
	delete(job.done_text)
	delete(job.failed_text)
	delete(job.refresh_path)
	free(job)
	free_all(context.temp_allocator)
}

@(private = "file")
is_success_status :: proc(status: int) -> bool {
	return status >= 200 && status < 300
}

@(private = "file")
to_failure_text :: proc(failed_text: string, status: int) -> string {
	if status == 0 do return fmt.aprintf("%s. Apple did not answer.", failed_text)

	return fmt.aprintf("%s. Apple answered %d.", failed_text, status)
}

apply_write_results :: proc() {
	sync.guard(&write_results.mutex)

	for text in write_results.toasts {
		kit.show_toast(text)
		delete(text)
	}

	for path in write_results.refresh {
		apple.refresh(path)
		delete(path)
	}

	for created in write_results.created {
		if len(created.youtube_songs) > 0 {
			youtube_lists.add_playlist_youtube_songs(created.id, created.youtube_songs)
		}

		kit.show_toast(created.done_text)
		apple.refresh(PLAYLISTS_PATH)

		if created.should_open_page {
			core.navigate({kind = .Playlist, id = created.id, title = created.name})
		}

		delete_created_playlist(created)
	}

	clear(&write_results.toasts)
	clear(&write_results.refresh)
	clear(&write_results.created)
}

@(private = "file")
Song_Reference :: struct {
	id:   string,
	type: string,
}

// Apple's playlists hold only Apple songs, so a song only on YouTube goes in onlymuse's own part.
add_to_playlist :: proc(playlist_id, playlist_name: string, chosen: core.Catalog_Song) {
	song := matching.watch_playable(chosen)

	if youtube.is_song_id(song.id) {
		youtube_lists.add_playlist_youtube_songs(playlist_id, {{"", song}})
		kit.show_toast(
			fmt.tprintf("Added %s to %s. It plays from YouTube.", song.name, playlist_name),
		)
		return
	}

	Body :: struct {
		data: []Song_Reference,
	}
	body, _ := json.marshal(Body{{{song.id, "songs"}}}, allocator = context.temp_allocator)

	start_write(
		{
			path = fmt.tprintf("/v1/me/library/playlists/%s/tracks", playlist_id),
			body = string(body),
			done_text = fmt.tprintf("Added %s to %s", song.name, playlist_name),
			failed_text = fmt.tprintf("Could not add %s to %s", song.name, playlist_name),
			refresh_path = fmt.tprintf(
				"/v1/me/library/playlists/%s/tracks?limit=100&offset=0",
				playlist_id,
			),
		},
	)
}

@(private)
create_playlist_with :: proc(name: string, chosen: core.Catalog_Song) {
	song := matching.watch_playable(chosen)
	done_text := fmt.tprintf("Made %s with %s", name, song.name)

	if youtube.is_song_id(song.id) {
		create_playlist(name, nil, {{"", song}}, done_text)
		return
	}

	create_playlist(name, {song}, nil, done_text)
}

PLAYLISTS_PATH :: "/v1/me/library/playlists?limit=100&offset=0"

@(private = "file")
Create_Job :: struct {
	using playlist: Created_Playlist,
	body:           string,
}

create_playlist :: proc(
	name: string,
	songs: []core.Catalog_Song,
	youtube_songs: []youtube_lists.Playlist_YouTube_Song,
	done_text: string,
	should_open_page := false,
) {
	Body :: struct {
		attributes:    struct {
			name: string,
		},
		relationships: struct {
			tracks: struct {
				data: []Song_Reference,
			},
		},
	}
	value: Body

	value.attributes.name = name
	references := make([]Song_Reference, len(songs), context.temp_allocator)
	for song, index in songs do references[index] = {song.id, "songs"}
	value.relationships.tracks.data = references

	body, _ := json.marshal(value, allocator = context.temp_allocator)

	kept := make([]youtube_lists.Playlist_YouTube_Song, len(youtube_songs))

	for song, index in youtube_songs {
		kept[index] = {strings.clone(song.after), core.copy_song(song.song)}
	}

	job := new(Create_Job)
	job^ = {
		playlist = {
			name = strings.clone(name),
			done_text = strings.clone(done_text),
			youtube_songs = kept,
			should_open_page = should_open_page,
		},
		body = strings.clone(string(body)),
	}

	thread.create_and_start_with_data(job, run_create, self_cleanup = true)
}

@(private = "file")
run_create :: proc(data: rawptr) {
	job := cast(^Create_Job)data

	defer net.stop_thread()
	defer free_all(context.temp_allocator)
	defer free(job)
	defer delete(job.body)

	answer := apple.post("/v1/me/library/playlists", job.body)
	resources :=
		apple.to_resources(answer.body, context.temp_allocator) if is_success_status(answer.status) else nil

	sync.guard(&write_results.mutex)
	defer platform.wake()

	if len(resources) == 0 {
		failed_text := fmt.tprintf("Could not make %s", job.name)
		append(&write_results.toasts, to_failure_text(failed_text, answer.status))
		delete_created_playlist(job.playlist)
		return
	}

	created := job.playlist
	created.id = strings.clone(resources[0].id)
	append(&write_results.created, created)
}

@(private = "file")
delete_created_playlist :: proc(playlist: Created_Playlist) {
	delete(playlist.id)
	delete(playlist.name)
	delete(playlist.done_text)

	for song in playlist.youtube_songs {
		delete(song.after)
		core.delete_song(song.song)
	}

	delete(playlist.youtube_songs)
}
