package net

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"

Response :: struct {
	status:       int,
	content_type: string,
	body:         []u8,
}

// A Safari User-Agent. Apple's servers reset more connections without one.
USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
TIMEOUT_MS :: 15_000
// Apple's image server sometimes resets a connection. It answers 429 or 5xx when it is busy.
@(private)
retry_delays := [?]time.Duration {
	250 * time.Millisecond,
	500 * time.Millisecond,
	1000 * time.Millisecond,
}

@(private, thread_local)
thread_handle: Curl

start :: proc() {
	curl_global_init(CURL_GLOBAL_DEFAULT)
}

stop_thread :: proc() {
	if thread_handle == nil do return

	curl_easy_cleanup(thread_handle)
	thread_handle = nil
}

@(private)
append_body :: proc "c" (data: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	context = runtime.default_context()
	body := cast(^[dynamic]u8)user
	append(body, ..data[:size * count])

	return size * count
}

Method :: enum {
	Get,
	Post,
}

// fetch never retries a POST. A retry after a lost answer could put a song in the library twice.
fetch :: proc(url: string, headers: []string = nil, method := Method.Get, body := "") -> Response {
	for attempt := 0;; attempt += 1 {
		response := fetch_once(url, headers, method, body)
		if method == .Post do return response

		is_retryable := response.status == 0 || response.status == 429 || response.status >= 500
		has_retries_left := attempt < len(retry_delays)

		if !is_retryable || !has_retries_left do return response

		delete(response.body, context.temp_allocator)
		time.sleep(retry_delays[attempt])
	}
}

@(private)
fetch_once :: proc(
	url: string,
	headers: []string,
	method: Method,
	request_body := "",
) -> Response {
	if thread_handle == nil do thread_handle = curl_easy_init()

	handle := thread_handle
	curl_easy_reset(handle)

	body := make([dynamic]u8, context.temp_allocator)
	header_list: Curl_List
	defer curl_slist_free_all(header_list)

	for header in headers {
		header_list = curl_slist_append(
			header_list,
			strings.clone_to_cstring(header, context.temp_allocator),
		)
	}

	curl_easy_setopt(handle, CURLOPT_URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl_easy_setopt(handle, CURLOPT_USERAGENT, cstring(USER_AGENT))
	curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, c.long(1))
	// libcurl's docs ask a program with threads to turn off curl's signals.
	curl_easy_setopt(handle, CURLOPT_NOSIGNAL, c.long(1))
	curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, c.long(TIMEOUT_MS))
	curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, Curl_Write_Proc(append_body))
	curl_easy_setopt(handle, CURLOPT_WRITEDATA, rawptr(&body))
	curl_easy_setopt(handle, CURLOPT_HTTPHEADER, rawptr(header_list))

	if method == .Post {
		curl_easy_setopt(handle, CURLOPT_POST, c.long(1))
		curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, c.long(len(request_body)))

		// POSTFIELDS keeps a pointer, not a copy. request_body lasts past curl_easy_perform.
		if request_body != "" {
			curl_easy_setopt(handle, CURLOPT_POSTFIELDS, raw_data(request_body))
		}
	}

	if curl_easy_perform(handle) != 0 {
		delete(body)
		return {}
	}

	status: c.long
	content_type: cstring

	curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status)
	curl_easy_getinfo(handle, CURLINFO_CONTENT_TYPE, &content_type)

	return Response {
		int(status),
		strings.clone_from_cstring(content_type, context.temp_allocator) if content_type != nil else "",
		body[:],
	}
}
