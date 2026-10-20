// Apple's API at amp-api.music.apple.com, with the web player's tokens.
package apple

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "om:store"
import "om:net"

BASE_URL :: "https://amp-api.music.apple.com"
// The storefront of the account, from /v1/me/storefront.
STOREFRONT :: "id"

// Requests wait for the helper's tokens until this long after the app starts, then go without.
@(private)
TOKEN_WAIT :: 30 * time.Second

Answer :: struct {
	// 0 when there was no answer.
	status: int,
	body:   string,
}

@(private)
state: struct {
	mutex:           sync.Mutex,
	developer_token: string,
	user_token:      string,
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
}

has_tokens :: proc() -> bool {
	sync.guard(&state.mutex)

	return state.developer_token != ""
}

// The saved answer when there is one, else Apple's, which is then saved. Safe on any thread, and it blocks. The body uses allocator.
fetch :: proc(path: string, allocator := context.allocator) -> Answer {
	if saved, ok := store.find_answer(path, allocator); ok do return {200, saved.body}

	answer := send_request(path, .Get, allocator)
	if answer.status == 200 do store.save_answer(path, answer.body)

	return answer
}

// Such as /v1/me/library?ids[songs]=1440857781, which puts a song in the library. Apple answers 202.
post :: proc(path: string) -> int {
	return send_request(path, .Post, context.temp_allocator).status
}

@(private)
send_request :: proc(path: string, method: net.Method, allocator := context.allocator) -> Answer {
	// The helper reads the tokens from a web page a moment after it starts.
	for !has_tokens() && time.tick_since(state.started) < TOKEN_WAIT do time.sleep(100 * time.Millisecond)

	headers: [4]string
	{
		sync.guard(&state.mutex)
		if state.developer_token == "" do return {}

		headers = {
			fmt.tprintf("Authorization: Bearer %s", state.developer_token),
			fmt.tprintf("media-user-token: %s", state.user_token),
			// The developer token only works for apple.com origins.
			"Origin: https://music.apple.com",
			"Accept: application/json",
		}
	}

	response := net.fetch(fmt.tprintf("%s%s", BASE_URL, path), headers[:], context.temp_allocator, method)

	return {response.status, strings.clone(string(response.body), allocator)}
}
