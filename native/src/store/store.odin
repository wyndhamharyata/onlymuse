// The app's SQLite file: Apple's answers and the saved state of the window, as in the gpuix app's
// src/store.ts. The first run copies the gpuix app's file, which is only ever read.
package store

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "om:mac"

Saved_Answer :: struct {
	body:       string,
	// Unix time in ms.
	fetched_at: i64,
}

@(private)
state: struct {
	db:    mac.Sqlite,
	mutex: sync.Mutex,
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
	create table if not exists state (
		key text primary key,
		value text not null,
		saved_at integer not null
	);
`

// OM_DATA names the folder, for the tests.
folder :: proc() -> string {
	if folder := os.get_env("OM_DATA", context.temp_allocator); folder != "" do return folder

	return fmt.tprintf("%s/Library/Application Support/onlymuse-native", os.get_env("HOME", context.temp_allocator))
}

@(private)
gpuix_path :: proc() -> string {
	return fmt.tprintf("%s/Library/Application Support/onlymuse/onlymuse.sqlite", os.get_env("HOME", context.temp_allocator))
}

start :: proc() {
	os.make_directory_all(folder())
	path := fmt.tprintf("%s/onlymuse.sqlite", folder())

	if !os.exists(path) && os.exists(gpuix_path()) do copy_gpuix_file(path)

	flags := i32(mac.SQLITE_OPEN_READWRITE | mac.SQLITE_OPEN_CREATE | mac.SQLITE_OPEN_FULLMUTEX)
	if mac.sqlite3_open_v2(strings.clone_to_cstring(path, context.temp_allocator), &state.db, flags, nil) != mac.SQLITE_OK {
		fmt.eprintfln("store: cannot open %s", path)
		return
	}

	// WAL lets a read go on during a write. NORMAL stays safe with WAL and skips a sync on every write.
	run("pragma journal_mode = wal; pragma synchronous = normal; pragma busy_timeout = 2000;")
	run(SCHEMA)
}

// VACUUM INTO writes a clean copy and reads the source only.
@(private)
copy_gpuix_file :: proc(path: string) {
	source: mac.Sqlite
	if mac.sqlite3_open_v2(strings.clone_to_cstring(gpuix_path(), context.temp_allocator), &source, mac.SQLITE_OPEN_READONLY, nil) != mac.SQLITE_OK do return
	defer mac.sqlite3_close(source)

	escaped, _ := strings.replace_all(path, "'", "''", context.temp_allocator)
	sql := strings.clone_to_cstring(fmt.tprintf("vacuum into '%s'", escaped), context.temp_allocator)
	if mac.sqlite3_exec(source, sql, nil, nil, nil) != mac.SQLITE_OK do fmt.eprintfln("store: cannot copy the gpuix app's file: %s", mac.sqlite3_errmsg(source))
}

@(private)
run :: proc(sql: cstring) {
	error_text: cstring
	if mac.sqlite3_exec(state.db, sql, nil, nil, &error_text) != mac.SQLITE_OK do fmt.eprintfln("store: %s", error_text)
}

@(private)
now_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

@(private)
bind_text :: proc(statement: mac.Sqlite_Statement, index: i32, text: string) {
	mac.sqlite3_bind_text(statement, index, raw_data(text), i32(len(text)), mac.SQLITE_TRANSIENT)
}

@(private)
prepare :: proc(sql: cstring) -> (mac.Sqlite_Statement, bool) {
	statement: mac.Sqlite_Statement
	is_ready := mac.sqlite3_prepare_v2(state.db, sql, -1, &statement, nil) == mac.SQLITE_OK

	return statement, is_ready
}

@(private)
column_text :: proc(statement: mac.Sqlite_Statement, column: i32, allocator := context.allocator) -> string {
	bytes := mac.sqlite3_column_text(statement, column)[:mac.sqlite3_column_bytes(statement, column)]

	return strings.clone(string(bytes), allocator)
}

find_answer :: proc(path: string, allocator := context.allocator) -> (Saved_Answer, bool) {
	statement, ok := prepare("select body, fetched_at from responses where path = ?")
	if !ok do return {}, false
	defer mac.sqlite3_finalize(statement)
	bind_text(statement, 1, path)

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return {}, false

	return {column_text(statement, 0, allocator), mac.sqlite3_column_int64(statement, 1)}, true
}

save_answer :: proc(path, body: string) {
	statement, ok := prepare(`insert into responses (path, body, etag, fetched_at, used_at) values (?1, ?2, null, ?3, ?3)
		on conflict (path) do update set body = ?2, fetched_at = ?3, used_at = ?3`)
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, path)
	bind_text(statement, 2, body)
	mac.sqlite3_bind_int64(statement, 3, now_ms())
	mac.sqlite3_step(statement)
}

// The bodies of every saved path that starts with prefix, ordered by the number after "offset=".
list_answers :: proc(prefix: string, allocator := context.allocator) -> []string {
	statement, ok := prepare("select body from responses where substr(path, 1, length(?1)) = ?1 order by cast(substr(path, instr(path, 'offset=') + 7) as integer)")
	if !ok do return nil
	defer mac.sqlite3_finalize(statement)
	bind_text(statement, 1, prefix)

	bodies := make([dynamic]string, allocator)
	for mac.sqlite3_step(statement) == mac.SQLITE_ROW do append(&bodies, column_text(statement, 0, allocator))

	return bodies[:]
}

// A saved value, as JSON.
find_state :: proc(key: string, allocator := context.allocator) -> (string, bool) {
	statement, ok := prepare("select value from state where key = ?")
	if !ok do return "", false
	defer mac.sqlite3_finalize(statement)
	bind_text(statement, 1, key)

	if mac.sqlite3_step(statement) != mac.SQLITE_ROW do return "", false

	return column_text(statement, 0, allocator), true
}

save_state :: proc(key, value: string) {
	sync.guard(&state.mutex)
	statement, ok := prepare("insert into state (key, value, saved_at) values (?1, ?2, ?3) on conflict (key) do update set value = ?2, saved_at = ?3")
	if !ok do return
	defer mac.sqlite3_finalize(statement)

	bind_text(statement, 1, key)
	bind_text(statement, 2, value)
	mac.sqlite3_bind_int64(statement, 3, now_ms())
	mac.sqlite3_step(statement)
}
