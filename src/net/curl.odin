package net

import "core:c"

foreign import curl "system:curl"

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
