// The library, read from Apple's saved answers.
package library

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:store"

Album :: struct {
	id:          string,
	name:        string,
	artist_name: string,
	// Has {w} and {h} in place of the size.
	artwork_url: string,
}

Song :: struct {
	id:               string,
	// The catalog ID, which Music.app's library songs also carry. Empty for a song only on the Mac.
	catalog_id:       string,
	name:             string,
	artist_name:      string,
	album_name:       string,
	duration_seconds: f64,
	artwork_url:      string,
}

Playlist :: struct {
	id:          string,
	name:        string,
	artwork_url: string,
}

@(private)
Item :: struct {
	id:         string,
	attributes: struct {
		name:          string,
		artist_name:   string `json:"artistName"`,
		album_name:    string `json:"albumName"`,
		duration_ms:   f64 `json:"durationInMillis"`,
		artwork:       struct {
			url: string,
		},
		play_params:   struct {
			catalog_id: string `json:"catalogId"`,
		} `json:"playParams"`,
	},
}

@(private)
Page_Answer :: struct {
	data: []Item,
}

// Every saved page of a library list, such as "/v1/me/library/albums?", in the order of its offsets.
@(private)
list_saved_items :: proc(path_prefix: string, allocator := context.allocator) -> []Item {
	items: [dynamic]Item

	for body in store.list_answers(path_prefix, context.temp_allocator) {
		answer: Page_Answer
		if json.unmarshal_string(body, &answer, allocator = allocator) != nil do continue

		append(&items, ..answer.data)
	}

	return items[:]
}

list_albums :: proc() -> []Album {
	items := list_saved_items("/v1/me/library/albums?")
	albums := make([]Album, len(items))

	for item, index in items {
		albums[index] = {item.id, item.attributes.name, item.attributes.artist_name, item.attributes.artwork.url}
	}

	return albums
}

list_songs :: proc() -> []Song {
	items := list_saved_items("/v1/me/library/songs?")
	songs := make([]Song, len(items))

	for item, index in items {
		attributes := item.attributes
		songs[index] = {item.id, attributes.play_params.catalog_id, attributes.name, attributes.artist_name, attributes.album_name, attributes.duration_ms / 1000, attributes.artwork.url}
	}

	return songs
}

list_playlists :: proc() -> []Playlist {
	items := list_saved_items("/v1/me/library/playlists?")
	playlists := make([]Playlist, len(items))

	for item, index in items {
		playlists[index] = {item.id, item.attributes.name, item.attributes.artwork.url}
	}

	return playlists
}

// Apple's artwork URL at a size in pixels.
to_artwork_url :: proc(template: string, size_pixels: int, allocator := context.temp_allocator) -> string {
	size := fmt.tprintf("%d", size_pixels)
	with_width, _ := strings.replace_all(template, "{w}", size, context.temp_allocator)
	with_height, _ := strings.replace_all(with_width, "{h}", size, context.temp_allocator)
	url, _ := strings.replace_all(with_height, "{f}", "jpg", allocator)

	return url
}

// The catalog ID of a song in the saved queue, found by its name and artist.
find_queue_song_id :: proc(name, artist: string, allocator := context.allocator) -> (string, bool) {
	Queue :: struct {
		songs: []struct {
			id:          string,
			name:        string,
			artist_name: string `json:"artistName"`,
		},
	}

	text, ok := store.find_state("queue", context.temp_allocator)
	if !ok do return "", false

	queue: Queue
	if json.unmarshal_string(text, &queue, allocator = context.temp_allocator) != nil do return "", false

	for song in queue.songs {
		if song.name == name && song.artist_name == artist do return strings.clone(song.id, allocator), true
	}

	return "", false
}
