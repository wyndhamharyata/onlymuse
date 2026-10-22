// This package sends HTTP requests through libcurl. Each thread keeps its own handle, so curl reuses its connections.
package net

import "base:runtime"
import "core:c"
import "core:strings"
import "core:time"
import "om:mac"

Response :: struct {
	// 0 when the request never got an answer.
	status:       int,
	content_type: string,
	body:         []u8,
}

// A Safari User-Agent. Apple's servers reset more connections without one.
USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
TIMEOUT_MS :: 15_000
// Apple's image server resets a connection now and then. It answers 429 or 5xx when it is busy. fetch tries those again.
@(private)
retry_delays := [?]time.Duration {
	250 * time.Millisecond,
	500 * time.Millisecond,
	1000 * time.Millisecond,
}

@(private, thread_local)
thread_handle: mac.Curl

start :: proc() {
	mac.curl_global_init(mac.CURL_GLOBAL_DEFAULT)
}

@(private)
append_body :: proc "c" (data: [^]u8, size, count: c.size_t, user: rawptr) -> c.size_t {
	// curl calls this from C with no Odin context. append needs a context for its allocator.
	context = runtime.default_context()
	body := cast(^[dynamic]u8)user
	append(body, ..data[:size * count])

	return size * count
}

Method :: enum {
	Get,
	// A POST carries a JSON body, or an empty one, as the requests that write to Apple's library take.
	Post,
}

// fetch blocks the thread until the answer comes. The body and the content type use allocator.
// fetch never sends a POST twice. A second try after a lost answer could put a song in the library twice.
fetch :: proc(
	url: string,
	headers: []string = nil,
	allocator := context.allocator,
	method := Method.Get,
	body := "",
) -> Response {
	for attempt := 0;; attempt += 1 {
		response := fetch_once(url, headers, method, allocator, body)
		if method == .Post do return response

		is_retryable := response.status == 0 || response.status == 429 || response.status >= 500

		if !is_retryable || attempt >= len(retry_delays) do return response

		delete(response.body, allocator)
		time.sleep(retry_delays[attempt])
	}
}

@(private)
fetch_once :: proc(
	url: string,
	headers: []string,
	method: Method,
	allocator := context.allocator,
	request_body := "",
) -> Response {
	if thread_handle == nil do thread_handle = mac.curl_easy_init()

	handle := thread_handle
	mac.curl_easy_reset(handle)

	body := make([dynamic]u8, allocator)
	header_list: mac.Curl_List
	defer mac.curl_slist_free_all(header_list)

	for header in headers {
		header_list = mac.curl_slist_append(
			header_list,
			strings.clone_to_cstring(header, context.temp_allocator),
		)
	}

	mac.curl_easy_setopt(
		handle,
		mac.CURLOPT_URL,
		strings.clone_to_cstring(url, context.temp_allocator),
	)
	mac.curl_easy_setopt(handle, mac.CURLOPT_USERAGENT, cstring(USER_AGENT))
	mac.curl_easy_setopt(handle, mac.CURLOPT_FOLLOWLOCATION, c.long(1))
	mac.curl_easy_setopt(handle, mac.CURLOPT_NOSIGNAL, c.long(1))
	mac.curl_easy_setopt(handle, mac.CURLOPT_TIMEOUT_MS, c.long(TIMEOUT_MS))
	mac.curl_easy_setopt(handle, mac.CURLOPT_WRITEFUNCTION, mac.Curl_Write_Proc(append_body))
	mac.curl_easy_setopt(handle, mac.CURLOPT_WRITEDATA, rawptr(&body))

	if header_list != nil {
		mac.curl_easy_setopt(handle, mac.CURLOPT_HTTPHEADER, rawptr(header_list))
	}

	if method == .Post {
		mac.curl_easy_setopt(handle, mac.CURLOPT_POST, c.long(1))
		mac.curl_easy_setopt(handle, mac.CURLOPT_POSTFIELDSIZE, c.long(len(request_body)))

		// curl reads the body during perform, which returns before request_body goes.
		if request_body != "" {
			mac.curl_easy_setopt(handle, mac.CURLOPT_POSTFIELDS, raw_data(request_body))
		}
	}

	if mac.curl_easy_perform(handle) != 0 {
		delete(body)
		return {}
	}

	status: c.long
	content_type: cstring

	mac.curl_easy_getinfo(handle, mac.CURLINFO_RESPONSE_CODE, &status)
	mac.curl_easy_getinfo(handle, mac.CURLINFO_CONTENT_TYPE, &content_type)

	return Response {
		int(status),
		strings.clone_from_cstring(content_type, allocator) if content_type != nil else "",
		body[:],
	}
}
