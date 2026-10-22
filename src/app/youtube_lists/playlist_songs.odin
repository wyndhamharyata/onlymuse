package youtube_lists

import "core:encoding/json"
import "core:strings"
import "om:app/core"
import "om:store"

// A library playlist can hold songs only on YouTube. Apple's cannot, so onlymuse keeps them,
// each after the Apple song it followed, by that song's catalog ID.
Playlist_YouTube_Song :: struct {
	after: string,
	song:  core.Catalog_Song,
}

// The value of after for a song before every Apple song. An empty after puts the song at the end.
PLAYLIST_START :: "start"

// By library playlist ID, under the state key "playlistYouTubeSongs".
// @(private = "file") hides this from every other file.
@(private = "file")
playlist_youtube_songs: map[string][dynamic]Playlist_YouTube_Song

@(private = "file")
is_playlist_songs_read: bool

// Counts up with each change, so a playlist page reads its songs again.
playlist_youtube_version: int

@(private = "file")
read_playlist_youtube_songs :: proc() {
	if is_playlist_songs_read do return

	is_playlist_songs_read = true

	// The temp allocator's memory lasts until the next frame starts.
	if text, ok := store.find_state("playlistYouTubeSongs", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &playlist_youtube_songs)
	}
}

@(private = "file")
save_playlist_youtube_songs :: proc() {
	playlist_youtube_version += 1

	bytes, error := json.marshal(playlist_youtube_songs, allocator = context.temp_allocator)
	if error == nil do store.save_state("playlistYouTubeSongs", string(bytes))
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

		ordered_remove(list, index)
		break
	}

	save_playlist_youtube_songs()
}

is_playlist_youtube_song :: proc(playlist_id, song_id: string) -> bool {
	read_playlist_youtube_songs()

	// or_else gives an empty list when the map holds no entry for playlist_id.
	for song in playlist_youtube_songs[playlist_id] or_else {} {
		if song.song.id == song_id {
			return true
		}
	}

	return false
}

// The playlist's Apple songs with its YouTube songs back in their places. allocator defaults to
// context.allocator, the heap, whose memory lasts until a call frees it.
merge_playlist_youtube_songs :: proc(
	playlist_id: string,
	songs: []core.Catalog_Song,
	allocator := context.allocator,
) -> []core.Catalog_Song {
	read_playlist_youtube_songs()

	extra := playlist_youtube_songs[playlist_id] or_else {}
	if len(extra) == 0 do return songs

	merged := make([dynamic]core.Catalog_Song, allocator)
	placed := make([]bool, len(extra), context.temp_allocator)

	place_after(&merged, extra, placed, PLAYLIST_START)

	for song in songs {
		append(&merged, song)
		place_after(&merged, extra, placed, song.id)
	}

	for song, index in extra do if !placed[index] do append(&merged, song.song)

	return merged[:]
}

@(private = "file")
place_after :: proc(
	merged: ^[dynamic]core.Catalog_Song,
	extra: [dynamic]Playlist_YouTube_Song,
	placed: []bool,
	after: string,
) {
	for song, index in extra {
		if placed[index] || song.after != after do continue

		append(merged, song.song)
		placed[index] = true
	}
}
