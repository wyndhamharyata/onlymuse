// Apple's API at amp-api.music.apple.com, with the web player's tokens.
package apple

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "om:library"
import "om:net"

BASE_URL :: "https://amp-api.music.apple.com"
// The storefront of the account, from /v1/me/storefront.
STOREFRONT :: "id"

// 30 seconds in steps of 100 ms.
@(private)
TOKEN_WAIT_COUNT :: 300

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

// The gpuix app's saved answer when it has one, else Apple's. Safe on any thread, and it blocks. The body uses allocator.
fetch :: proc(path: string, allocator := context.allocator) -> Answer {
	if saved, ok := library.find_saved_answer(path, allocator); ok do return {200, saved}

	// The helper reads the tokens from a web page a moment after it starts.
	for wait_count := 0; !has_tokens() && wait_count < TOKEN_WAIT_COUNT; wait_count += 1 do time.sleep(100 * time.Millisecond)

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

	response := net.fetch(fmt.tprintf("%s%s", BASE_URL, path), headers[:], context.temp_allocator)

	return {response.status, strings.clone(string(response.body), allocator)}
}
