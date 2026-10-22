package mac

import "core:c"

foreign import sqlite "system:sqlite3"
foreign import curl "system:curl"
foreign import core_graphics_names "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign core_graphics_names {
	kCGColorSpaceSRGB: String_Ref

	CGColorSpaceCreateWithName :: proc(name: String_Ref) -> Color_Space_Ref ---
}

Sqlite :: distinct rawptr
Sqlite_Statement :: distinct rawptr

SQLITE_OPEN_READONLY :: 0x1
SQLITE_OPEN_READWRITE :: 0x2
SQLITE_OPEN_CREATE :: 0x4
// One connection serves every thread, and SQLite takes turns.
SQLITE_OPEN_FULLMUTEX :: 0x10000
SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
// SQLite copies a bound text at once.
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c")
foreign sqlite {
	sqlite3_open_v2 :: proc(path: cstring, db: ^Sqlite, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_close :: proc(db: Sqlite) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: Sqlite, sql: cstring, byte_count: c.int, statement: ^Sqlite_Statement, tail: ^cstring) -> c.int ---
	sqlite3_bind_text :: proc(statement: Sqlite_Statement, index: c.int, text: [^]u8, byte_count: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(statement: Sqlite_Statement, index: c.int, value: i64) -> c.int ---
	sqlite3_column_int64 :: proc(statement: Sqlite_Statement, column: c.int) -> i64 ---
	sqlite3_exec :: proc(db: Sqlite, sql: cstring, callback: rawptr, data: rawptr, error_text: ^cstring) -> c.int ---
	sqlite3_step :: proc(statement: Sqlite_Statement) -> c.int ---
	sqlite3_column_text :: proc(statement: Sqlite_Statement, column: c.int) -> [^]u8 ---
	sqlite3_column_bytes :: proc(statement: Sqlite_Statement, column: c.int) -> c.int ---
	sqlite3_finalize :: proc(statement: Sqlite_Statement) -> c.int ---
	sqlite3_errmsg :: proc(db: Sqlite) -> cstring ---
}

Curl :: distinct rawptr
Curl_List :: distinct rawptr

CURLOPT_WRITEDATA :: 10001
CURLOPT_URL :: 10002
CURLOPT_USERAGENT :: 10018
CURLOPT_HTTPHEADER :: 10023
CURLOPT_FOLLOWLOCATION :: 52
CURLOPT_POST :: 47
CURLOPT_POSTFIELDSIZE :: 60
CURLOPT_POSTFIELDS :: 10015
CURLOPT_NOSIGNAL :: 99
CURLOPT_TIMEOUT_MS :: 155
CURLOPT_WRITEFUNCTION :: 20011
CURLINFO_CONTENT_TYPE :: 0x100000 + 18
CURLINFO_RESPONSE_CODE :: 0x200000 + 2
CURL_GLOBAL_DEFAULT :: 3

Curl_Write_Proc :: #type proc "c" (data: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t

@(default_calling_convention = "c")
foreign curl {
	curl_global_init :: proc(flags: c.long) -> c.int ---
	curl_easy_init :: proc() -> Curl ---
	curl_easy_cleanup :: proc(handle: Curl) ---
	curl_easy_reset :: proc(handle: Curl) ---
	curl_easy_setopt :: proc(handle: Curl, option: c.int, #c_vararg arguments: ..any) -> c.int ---
	curl_easy_perform :: proc(handle: Curl) -> c.int ---
	curl_easy_getinfo :: proc(handle: Curl, info: c.int, #c_vararg arguments: ..any) -> c.int ---
	curl_slist_append :: proc(list: Curl_List, text: cstring) -> Curl_List ---
	curl_slist_free_all :: proc(list: Curl_List) ---
}
