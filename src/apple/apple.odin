package apple

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "om:console"
import "om:helper"
import "om:net"
import "om:store"

BASE_URL :: "https://amp-api.music.apple.com"
STOREFRONT :: "id"

@(private)
TOKEN_WAIT :: 30 * time.Second

Answer :: struct {
	status: int,
	body:   string,
}

@(private)
state: struct {
	mutex:           sync.Mutex,
	developer_token: string,
	user_token:      string,
	token_version:   int,
	started:         time.Tick,
}

start :: proc() {
	state.started = time.tick_now()
	thread.pool_init(&cache.pool, context.allocator, CHECK_THREAD_COUNT)
	thread.pool_start(&cache.pool)
}

set_tokens :: proc(developer_token, user_token: string) {
	sync.guard(&state.mutex)
	delete(state.developer_token)
	delete(state.user_token)
	state.developer_token = strings.clone(developer_token)
	state.user_token = strings.clone(user_token)
	state.token_version += 1
}

has_tokens :: proc() -> bool {
	sync.guard(&state.mutex)

	return state.developer_token != ""
}

fetch :: proc(path: string, allocator := context.allocator) -> Answer {
	if saved, ok := store.find_answer(path, allocator); ok do return {200, saved.body}

	answer := fetch_from_source(path, allocator)
	if answer.status == 200 do store.save_answer(path, answer.body)

	return answer
}

// The path /v1/me/library?ids[songs]=1440857781 puts that song in the library. Apple answers 202.
post :: proc(path: string, body := "") -> Answer {
	return fetch_from_apple(path, .Post, context.temp_allocator, body)
}

LANGUAGE :: "en-GB"

// Apple answers 401 or 403 once a token expires. The helper then reads fresh tokens.
@(private)
fetch_from_apple :: proc(
	path: string,
	method: net.Method,
	allocator := context.allocator,
	body := "",
) -> Answer {
	sent_version: int

	{
		sync.guard(&state.mutex)
		sent_version = state.token_version
	}

	answer := fetch_from_apple_once(path, method, allocator, body)
	is_token_refused := answer.status == 401 || answer.status == 403
	if !is_token_refused do return answer

	is_refresh_needed := false

	{
		sync.guard(&state.mutex)

		is_first_refusal := state.token_version == sent_version && state.developer_token != ""

		if is_first_refusal {
			delete(state.developer_token)
			state.developer_token = ""
			state.started = time.tick_now()
			is_refresh_needed = true
		}
	}

	if is_refresh_needed do helper.send_refresh_tokens()
	delete(answer.body, allocator)

	return fetch_from_apple_once(path, method, allocator, body)
}

@(private)
fetch_from_apple_once :: proc(
	path: string,
	method: net.Method,
	allocator := context.allocator,
	body := "",
) -> Answer {
	for !has_tokens() && time.tick_since(state.started) < TOKEN_WAIT {
		time.sleep(100 * time.Millisecond)
	}

	headers := make([dynamic]string, context.temp_allocator)

	{
		sync.guard(&state.mutex)

		if state.developer_token == "" {
			console.add(
				"Apple",
				"No token from the web player. onlymuse did not ask Apple for %s.",
				path,
			)
			return {}
		}

		append(&headers, fmt.tprintf("Authorization: Bearer %s", state.developer_token))
		append(&headers, fmt.tprintf("media-user-token: %s", state.user_token))
	}

	// The developer token only works for apple.com origins.
	append(&headers, "Origin: https://music.apple.com", "Accept: application/json")
	if body != "" do append(&headers, "Content-Type: application/json")

	separator := "&" if strings.contains(path, "?") else "?"
	url := fmt.tprintf("%s%s%sl=%s", BASE_URL, path, separator, LANGUAGE)
	response := net.fetch(url, headers[:], context.temp_allocator, method, body)
	is_refused := response.status < 200 || response.status >= 300

	if is_refused {
		console.add(
			"Apple",
			"%s %s: %s",
			"POST" if method == .Post else "GET",
			path,
			console.to_status_text(response.status),
		)
	}

	return {response.status, strings.clone(string(response.body), allocator)}
}

to_query_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	for byte_value in transmute([]u8)text {
		is_plain :=
			(byte_value >= 'a' && byte_value <= 'z') ||
			(byte_value >= 'A' && byte_value <= 'Z') ||
			(byte_value >= '0' && byte_value <= '9') ||
			byte_value == '-' ||
			byte_value == '.' ||
			byte_value == '_'

		if is_plain {
			strings.write_byte(&builder, byte_value)
		} else {
			fmt.sbprintf(&builder, "%%%02X", byte_value)
		}
	}

	return strings.to_string(builder)
}
