package store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "om:console"
import "om:mac"

MAX_ANSWER_AGE_DAYS :: 60

Saved_Answer :: struct {
	body:          string,
	fetched_at_ms: i64,
}

@(private)
state: struct {
	database: mac.Sqlite,
}

@(private)
SCHEMA :: `
	create table if not exists responses (
		path text primary key,
		body text not null,
		etag text,
		fetched_at integer not null,
		used_at integer not null
	);
	create table if not exists plays (
		catalog_id text not null,
		name text not null,
		artist text not null,
		album text not null,
		is_skip integer not null,
		played_at integer not null
	);
	create index if not exists plays_by_time on plays (played_at);
	create table if not exists state (
		key text primary key,
		value text not null,
		saved_at integer not null
	);
	create table if not exists matches (
		youtube_id text primary key,
		song text not null,
		checked_at integer not null
	);
	create table if not exists rejected_matches (
		youtube_id text primary key
	);
`


read_folder :: proc() -> string {
	if folder := os.get_env("OM_DATA", context.temp_allocator); folder != "" do return folder

	return fmt.tprintf(
		"%s/Library/Application Support/onlymuse-native",
		os.get_env("HOME", context.temp_allocator),
	)
}

start :: proc() {
	folder := read_folder()
	os.make_directory_all(folder)
	path := fmt.tprintf("%s/onlymuse.sqlite", folder)

	// FULLMUTEX lets several threads share this one connection.
	flags := i32(mac.SQLITE_OPEN_READWRITE | mac.SQLITE_OPEN_CREATE | mac.SQLITE_OPEN_FULLMUTEX)

	if mac.sqlite3_open_v2(
		   strings.clone_to_cstring(path, context.temp_allocator),
		   &state.database,
		   flags,
		   nil,
	   ) !=
	   mac.SQLITE_OK {
		console.add("Store", "Cannot open %s", path)
		return
	}

	// WAL lets a read go on during a write. With WAL, NORMAL stays safe and skips a sync per write.
	run("pragma journal_mode = wal; pragma synchronous = normal; pragma busy_timeout = 2000;")
	run(SCHEMA)
	run(
		fmt.ctprintf(
			"delete from responses where fetched_at < (unixepoch() - %d) * 1000;",
			MAX_ANSWER_AGE_DAYS * 24 * 60 * 60,
		),
	)
}

@(private)
run :: proc(sql: cstring) {
	error_text: cstring

	if mac.sqlite3_exec(state.database, sql, nil, nil, &error_text) != mac.SQLITE_OK {
		console.add("Store", "%s", error_text)
	}
}

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
bind_text :: proc(statement: mac.Sqlite_Statement, index: i32, text: string) {
	// SQLITE_TRANSIENT makes SQLite copy the text before this call returns.
	mac.sqlite3_bind_text(statement, index, raw_data(text), i32(len(text)), mac.SQLITE_TRANSIENT)
}

@(private)
prepare :: proc(sql: cstring) -> (mac.Sqlite_Statement, bool) {
	statement: mac.Sqlite_Statement
	is_ready := mac.sqlite3_prepare_v2(state.database, sql, -1, &statement, nil) == mac.SQLITE_OK

	return statement, is_ready
}

@(private)
step_write :: proc(statement: mac.Sqlite_Statement) {
	if mac.sqlite3_step(statement) != mac.SQLITE_DONE {
		console.add("Store", "%s", mac.sqlite3_errmsg(state.database))
	}
}

@(private)
read_column_text :: proc(
	statement: mac.Sqlite_Statement,
	column: i32,
	allocator := context.allocator,
) -> string {
	bytes := mac.sqlite3_column_text(statement, column)[:mac.sqlite3_column_bytes(
		statement,
		column,
	)]

	return strings.clone(string(bytes), allocator)
}

find_answer :: proc(path: string, allocator := context.allocator) -> (Saved_Answer, bool) {
	statement, ok := prepare("select body, fetched_at from responses where path = ?")
	if !ok do return {}, false
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, path)

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return {}, false

	return {read_column_text(statement, 0, allocator), mac.sqlite3_column_int64(statement, 1)},
		true
}

save_answer :: proc(path, body: string) {
	statement, ok := prepare(
		`insert into responses (path, body, etag, fetched_at, used_at) values (?1, ?2, null, ?3, ?3)
		on conflict (path) do update set body = ?2, fetched_at = ?3, used_at = ?3`,
	)
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, path)
	bind_text(statement, 2, body)
	mac.sqlite3_bind_int64(statement, 3, now_ms())
	step_write(statement)
}

find_state :: proc(key: string, allocator := context.allocator) -> (string, bool) {
	statement, ok := prepare("select value from state where key = ?")
	if !ok do return "", false
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, key)

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return "", false

	return read_column_text(statement, 0, allocator), true
}

save_state :: proc(key, value: string) {
	statement, ok := prepare(
		"insert into state (key, value, saved_at) values (?1, ?2, ?3) on conflict (key) do update set value = ?2, saved_at = ?3",
	)
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, key)
	bind_text(statement, 2, value)
	mac.sqlite3_bind_int64(statement, 3, now_ms())
	step_write(statement)
}

find_match :: proc(youtube_id: string, allocator := context.allocator) -> (string, bool) {
	statement, ok := prepare("select song from matches where youtube_id = ?")
	if !ok do return "", false
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, youtube_id)

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return "", false

	return read_column_text(statement, 0, allocator), true
}

is_match_rejected :: proc(youtube_id: string) -> bool {
	statement, ok := prepare("select 1 from rejected_matches where youtube_id = ?")
	if !ok do return false
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, youtube_id)

	return mac.sqlite3_step(statement) == mac.SQLITE_ROW
}

save_rejected_match :: proc(youtube_id: string) {
	statement, ok := prepare("insert or ignore into rejected_matches (youtube_id) values (?1)")
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, youtube_id)
	step_write(statement)
}

delete_rejected_match :: proc(youtube_id: string) {
	statement, ok := prepare("delete from rejected_matches where youtube_id = ?1")
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, youtube_id)
	step_write(statement)
}

delete_matches :: proc() {
	run("delete from matches")
}

save_match :: proc(youtube_id, song_json: string) {
	statement, ok := prepare(
		"insert into matches (youtube_id, song, checked_at) values (?1, ?2, ?3) on conflict (youtube_id) do update set song = ?2, checked_at = ?3",
	)
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, youtube_id)
	bind_text(statement, 2, song_json)
	mac.sqlite3_bind_int64(statement, 3, now_ms())
	step_write(statement)
}

// Music.app keeps only a count and the last date.
Play :: struct {
	catalog_id:   string,
	name:         string,
	artist:       string,
	album:        string,
	is_skip:      bool,
	played_at_ms: i64,
}

save_play :: proc(play: Play) {
	statement, ok := prepare(
		"insert into plays (catalog_id, name, artist, album, is_skip, played_at) values (?1, ?2, ?3, ?4, ?5, ?6)",
	)
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, play.catalog_id)
	bind_text(statement, 2, play.name)
	bind_text(statement, 3, play.artist)
	bind_text(statement, 4, play.album)
	mac.sqlite3_bind_int64(statement, 5, 1 if play.is_skip else 0)
	mac.sqlite3_bind_int64(statement, 6, play.played_at_ms if play.played_at_ms > 0 else now_ms())
	step_write(statement)
}

list_plays :: proc(since_ms: i64, allocator := context.allocator) -> []Play {
	statement, ok := prepare(
		"select catalog_id, name, artist, album, is_skip, played_at from plays where played_at >= ?1 order by played_at",
	)
	if !ok do return nil
	defer mac.sqlite3_finalize(statement)

	mac.sqlite3_bind_int64(statement, 1, since_ms)

	plays := make([dynamic]Play, allocator)

	for mac.sqlite3_step(statement) == mac.SQLITE_ROW {
		append(
			&plays,
			Play {
				catalog_id = read_column_text(statement, 0, allocator),
				name = read_column_text(statement, 1, allocator),
				artist = read_column_text(statement, 2, allocator),
				album = read_column_text(statement, 3, allocator),
				is_skip = mac.sqlite3_column_int64(statement, 4) != 0,
				played_at_ms = mac.sqlite3_column_int64(statement, 5),
			},
		)
	}

	return plays[:]
}
