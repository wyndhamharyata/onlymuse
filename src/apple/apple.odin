// Apple's API at amp-api.music.apple.com, with the web player's tokens.
package apple

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "om:console"
import "om:helper"
import "om:net"
import "om:store"

BASE_URL :: "https://amp-api.music.apple.com"
// The storefront of the account, from /v1/me/storefront.
STOREFRONT :: "id"

// Requests wait for the helper's tokens until this long after the app starts, then go without.
@(private)
TOKEN_WAIT :: 30 * time.Second

Answer :: struct {
	// 0 when no answer came.
	status: int,
	body:   string,
}

@(private)
state: struct {
	mutex:           sync.Mutex,
	developer_token: string,
	user_token:      string,
	// Counts up with each new pair of tokens.
	token_version:   int,
	started:         time.Tick,
}

start :: proc() {
	state.started = time.tick_now()
}

// The helper reads the tokens from a hidden music.apple.com page.
set_tokens :: proc(developer_token, user_token: string) {
	sync.guard(&state.mutex)
	delete(state.developer_token)
	delete(state.user_token)
	state.developer_token = strings.clone(developer_token)
	state.user_token = strings.clone(user_token)
	state.token_version += 1
}

@(private)
read_token_version :: proc() -> int {
	sync.guard(&state.mutex)

	return state.token_version
}

has_tokens :: proc() -> bool {
	sync.guard(&state.mutex)

	return state.developer_token != ""
}

// The saved answer when there is one, else Apple's, which fetch then saves. It blocks.
// Any thread may call it.
fetch :: proc(path: string, allocator := context.allocator) -> Answer {
	if saved, ok := store.find_answer(path, allocator); ok do return {200, saved.body}

	answer := send_to_source(path, allocator)
	if answer.status == 200 do store.save_answer(path, answer.body)

	return answer
}

// The path /v1/me/library?ids[songs]=1440857781 puts that song in the library. Apple answers 202.
// A JSON body goes with a playlist's new songs. It blocks, so a worker thread calls it.
post :: proc(path: string, body := "") -> Answer {
	return send_request(path, .Post, context.temp_allocator, body)
}

// The language of the answers. The saved path does not hold it, as every answer is in it.
@(private)
LANGUAGE :: "en-GB"

// Apple answers 401 or 403 once a token expires. The helper then reads fresh tokens.
// send_request then sends the request one more time.
@(private)
send_request :: proc(
	path: string,
	method: net.Method,
	allocator := context.allocator,
	body := "",
) -> Answer {
	sent_version := read_token_version()
	answer := send_once(path, method, allocator, body)
	if answer.status != 401 && answer.status != 403 do return answer

	// Another refusal may bring fresh tokens while this request waits. It then keeps those tokens.
	is_refresh_needed := false

	{
		sync.guard(&state.mutex)

		if state.token_version == sent_version && state.developer_token != "" {
			delete(state.developer_token)
			state.developer_token = ""
			state.started = time.tick_now()
			is_refresh_needed = true
		}
	}

	if is_refresh_needed do helper.send(`{"type":"refreshTokens"}`)
	delete(answer.body, allocator)

	return send_once(path, method, allocator, body)
}

@(private)
send_once :: proc(
	path: string,
	method: net.Method,
	allocator := context.allocator,
	body := "",
) -> Answer {
	// The helper reads the tokens from a web page a moment after it starts.
	for !has_tokens() && time.tick_since(state.started) < TOKEN_WAIT {
		time.sleep(100 * time.Millisecond)
	}

	headers: [5]string
	header_count := 4

	{
		sync.guard(&state.mutex)

		if state.developer_token == "" {
			console.add("Apple", "No token from the web player, so %s was not asked.", path)
			return {}
		}

		headers = {
			fmt.tprintf("Authorization: Bearer %s", state.developer_token),
			fmt.tprintf("media-user-token: %s", state.user_token),
			// The developer token only works for apple.com origins.
			"Origin: https://music.apple.com",
			"Accept: application/json",
			"Content-Type: application/json",
		}
	}

	if body != "" do header_count = 5

	separator := "&" if strings.contains(path, "?") else "?"
	url := fmt.tprintf("%s%s%sl=%s", BASE_URL, path, separator, LANGUAGE)
	response := net.fetch(url, headers[:header_count], context.temp_allocator, method, body)
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

// Text for a URL's query, with every byte but letters, digits and -._ written as %XX.
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
