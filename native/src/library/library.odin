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

@(private)
Albums_Answer :: struct {
	data: []struct {
		id:         string,
		attributes: struct {
			name:        string,
			artist_name: string `json:"artistName"`,
			artwork:     struct {
				url: string,
			},
		},
	},
}

// OM_DATA names the folder of the SQLite file, for the tests. It is only read.
data_path :: proc() -> string {
	folder := os.get_env("OM_DATA", context.temp_allocator)

	if folder == "" do folder = fmt.tprintf("%s/Library/Application Support/onlymuse", os.get_env("HOME", context.temp_allocator))

	return fmt.tprintf("%s/onlymuse.sqlite", folder)
}

// Every saved page of /v1/me/library/albums, in order.
list_albums :: proc() -> []Album {
	db: mac.Sqlite
	path := strings.clone_to_cstring(data_path(), context.temp_allocator)

	if mac.sqlite3_open_v2(path, &db, mac.SQLITE_OPEN_READONLY, nil) != mac.SQLITE_OK {
		fmt.eprintfln("library: cannot open %s", path)
		return nil
	}
	defer mac.sqlite3_close(db)

	sql: cstring = "select body from responses where path like '/v1/me/library/albums?%' order by cast(substr(path, instr(path, 'offset=') + 7) as integer)"
	statement: mac.Sqlite_Statement
	if mac.sqlite3_prepare_v2(db, sql, -1, &statement, nil) != mac.SQLITE_OK do return nil
	defer mac.sqlite3_finalize(statement)

	albums: [dynamic]Album

	for mac.sqlite3_step(statement) == mac.SQLITE_ROW {
		body := mac.sqlite3_column_text(statement, 0)[:mac.sqlite3_column_bytes(statement, 0)]
		answer: Albums_Answer

		if json.unmarshal(body, &answer, allocator = context.temp_allocator) != nil do continue

		for item in answer.data {
			album := Album {
				id          = strings.clone(item.id),
				name        = strings.clone(item.attributes.name),
				artist_name = strings.clone(item.attributes.artist_name),
				artwork_url = strings.clone(item.attributes.artwork.url),
			}
			append(&albums, album)
		}
	}

	return albums[:]
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
