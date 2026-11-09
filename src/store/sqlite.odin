package store

import "core:c"

foreign import sqlite "system:sqlite3"

Sqlite :: distinct rawptr
Sqlite_Statement :: distinct rawptr

SQLITE_OPEN_READWRITE :: 0x2
SQLITE_OPEN_CREATE :: 0x4
SQLITE_OPEN_FULLMUTEX :: 0x10000
SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
// SQLite copies a bound text at once.
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open_v2 :: proc(path: cstring, database: ^Sqlite, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_prepare_v2 :: proc(database: Sqlite, sql: cstring, byte_count: c.int, statement: ^Sqlite_Statement, tail: ^cstring) -> c.int ---
	sqlite3_bind_text :: proc(statement: Sqlite_Statement, index: c.int, text: [^]u8, byte_count: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(statement: Sqlite_Statement, index: c.int, value: i64) -> c.int ---
	sqlite3_column_int64 :: proc(statement: Sqlite_Statement, column: c.int) -> i64 ---
	sqlite3_exec :: proc(database: Sqlite, sql: cstring, callback: rawptr, data: rawptr, error_text: ^cstring) -> c.int ---
	sqlite3_step :: proc(statement: Sqlite_Statement) -> c.int ---
	sqlite3_column_text :: proc(statement: Sqlite_Statement, column: c.int) -> [^]u8 ---
	sqlite3_column_bytes :: proc(statement: Sqlite_Statement, column: c.int) -> c.int ---
	sqlite3_finalize :: proc(statement: Sqlite_Statement) -> c.int ---
	sqlite3_errmsg :: proc(database: Sqlite) -> cstring ---
}
