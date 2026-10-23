package youtube_lists

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "om:app/core"
import "om:store"

Playlist_YouTube_Song :: struct {
	after: string,
	song:  core.Catalog_Song,
}

PLAYLIST_START :: "start"

@(private = "file")
PLAYLIST_YOUTUBE_SONGS_KEY :: "playlistYouTubeSongs"

@(private = "file")
playlist_youtube_songs: map[string][dynamic]Playlist_YouTube_Song

@(private = "file")
is_playlist_songs_read: bool

playlist_youtube_version: int

@(private = "file")
read_playlist_youtube_songs :: proc() {
	if is_playlist_songs_read do return

	is_playlist_songs_read = true

	if text, ok := store.find_state(PLAYLIST_YOUTUBE_SONGS_KEY, context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &playlist_youtube_songs)
	}
}

@(private = "file")
save_playlist_youtube_songs :: proc() {
	playlist_youtube_version += 1

	bytes, error := json.marshal(playlist_youtube_songs, allocator = context.temp_allocator)
	if error == nil do store.save_state(PLAYLIST_YOUTUBE_SONGS_KEY, string(bytes))
}

add_playlist_youtube_songs :: proc(playlist_id: string, songs: []Playlist_YouTube_Song) {
	read_playlist_youtube_songs()

	if playlist_id not_in playlist_youtube_songs {
		playlist_youtube_songs[strings.clone(playlist_id)] = {}
	}

	list := &playlist_youtube_songs[playlist_id]

	for song in songs {
		append(list, Playlist_YouTube_Song{strings.clone(song.after), core.copy_song(song.song)})
	}

	save_playlist_youtube_songs()
}

remove_playlist_youtube_song :: proc(playlist_id, song_id: string) {
	read_playlist_youtube_songs()

	list, ok := &playlist_youtube_songs[playlist_id]
	if !ok do return

	for song, index in list {
		if song.song.id != song_id do continue

		delete(song.after)
		core.delete_song(song.song)
		ordered_remove(list, index)
		save_playlist_youtube_songs()
		return
	}
}

is_playlist_youtube_song :: proc(playlist_id, song_id: string) -> bool {
	read_playlist_youtube_songs()

	for song in playlist_youtube_songs[playlist_id] or_else {} {
		if song.song.id == song_id {
			return true
		}
	}

	return false
}

merge_playlist_youtube_songs :: proc(
	playlist_id: string,
	songs: []core.Catalog_Song,
	allocator: mem.Allocator,
) -> []core.Catalog_Song {
	read_playlist_youtube_songs()

	extra := playlist_youtube_songs[playlist_id] or_else {}
	if len(extra) == 0 do return songs

	merged := make([dynamic]core.Catalog_Song, allocator)
	placed := make([]bool, len(extra), context.temp_allocator)

	place_after(&merged, extra[:], placed, PLAYLIST_START, allocator)

	for song in songs {
		append(&merged, song)
		place_after(&merged, extra[:], placed, song.id, allocator)
	}

	for song, index in extra {
		if !placed[index] do append(&merged, core.copy_song(song.song, allocator))
	}

	return merged[:]
}

@(private = "file")
place_after :: proc(
	merged: ^[dynamic]core.Catalog_Song,
	extra: []Playlist_YouTube_Song,
	placed: []bool,
	after: string,
	allocator: mem.Allocator,
) {
	for song, index in extra {
		if placed[index] || song.after != after do continue

		append(merged, core.copy_song(song.song, allocator))
		placed[index] = true
	}
}
