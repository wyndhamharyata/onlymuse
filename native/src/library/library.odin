// The library, read from the answers of Apple's API that the gpuix app saved in its SQLite file.
package library

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "om:mac"

Album :: struct {
	id:          string,
	name:        string,
	artist_name: string,
	// Has {w} and {h} in place of the size.
	artwork_url: string,
}

// OM_DATA names the folder of the SQLite file, for the tests. It is only read.
data_path :: proc() -> string {
	folder := os.get_env("OM_DATA", context.temp_allocator)

	if folder == "" do folder = fmt.tprintf("%s/Library/Application Support/onlymuse", os.get_env("HOME", context.temp_allocator))

	return fmt.tprintf("%s/onlymuse.sqlite", folder)
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
	db: mac.Sqlite
	path := strings.clone_to_cstring(data_path(), context.temp_allocator)

	if mac.sqlite3_open_v2(path, &db, mac.SQLITE_OPEN_READONLY, nil) != mac.SQLITE_OK {
		fmt.eprintfln("library: cannot open %s", path)
		return nil
	}
	defer mac.sqlite3_close(db)

	sql: cstring = "select body from responses where substr(path, 1, length(?1)) = ?1 order by cast(substr(path, instr(path, 'offset=') + 7) as integer)"
	statement: mac.Sqlite_Statement
	if mac.sqlite3_prepare_v2(db, sql, -1, &statement, nil) != mac.SQLITE_OK do return nil
	defer mac.sqlite3_finalize(statement)

	// SQLITE_TRANSIENT: SQLite copies the text.
	mac.sqlite3_bind_text(statement, 1, raw_data(path_prefix), i32(len(path_prefix)), rawptr(~uintptr(0)))
	items: [dynamic]Item

	for mac.sqlite3_step(statement) == mac.SQLITE_ROW {
		body := mac.sqlite3_column_text(statement, 0)[:mac.sqlite3_column_bytes(statement, 0)]
		answer: Page_Answer

		if json.unmarshal(body, &answer, allocator = allocator) != nil do continue

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

// Runs sql with one text parameter and returns the first column of the first row.
@(private)
read_one_text :: proc(sql: cstring, parameter: string, allocator := context.allocator) -> (string, bool) {
	db: mac.Sqlite
	path := strings.clone_to_cstring(data_path(), context.temp_allocator)

	if mac.sqlite3_open_v2(path, &db, mac.SQLITE_OPEN_READONLY, nil) != mac.SQLITE_OK do return "", false
	defer mac.sqlite3_close(db)

	statement: mac.Sqlite_Statement
	if mac.sqlite3_prepare_v2(db, sql, -1, &statement, nil) != mac.SQLITE_OK do return "", false
	defer mac.sqlite3_finalize(statement)

	// SQLITE_TRANSIENT: SQLite copies the text.
	mac.sqlite3_bind_text(statement, 1, raw_data(parameter), i32(len(parameter)), rawptr(~uintptr(0)))

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return "", false

	text := mac.sqlite3_column_text(statement, 0)[:mac.sqlite3_column_bytes(statement, 0)]

	return strings.clone(string(text), allocator), true
}

// The answer the gpuix app saved for an API path, such as a song's lyrics.
find_saved_answer :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	return read_one_text("select body from responses where path = ?", path, allocator)
}

// A saved value of the gpuix app's window, as JSON, such as "lyricLeadMs".
find_saved_state :: proc(key: string, allocator := context.allocator) -> (string, bool) {
	return read_one_text("select value from state where key = ?", key, allocator)
}

// The catalog ID of a song in the gpuix app's saved queue, found by its name and artist.
find_queue_song_id :: proc(name, artist: string, allocator := context.allocator) -> (string, bool) {
	Queue :: struct {
		songs: []struct {
			id:          string,
			name:        string,
			artist_name: string `json:"artistName"`,
		},
	}

	text, ok := find_saved_state("queue", context.temp_allocator)
	if !ok do return "", false

	queue: Queue
	if json.unmarshal_string(text, &queue, allocator = context.temp_allocator) != nil do return "", false

	for song in queue.songs {
		if song.name == name && song.artist_name == artist do return strings.clone(song.id, allocator), true
	}

	return "", false
}
