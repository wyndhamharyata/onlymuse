// YouTube Music's own web API at music.youtube.com, with the sign-in the helper reads from its web page.
package youtube

import "core:crypto/legacy/sha1"
import "core:encoding/json"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "om:console"
import "om:apple"
import "om:net"

BASE_URL :: "https://music.youtube.com/youtubei/v1/"
ORIGIN :: "https://music.youtube.com"
// The web player's own version. YouTube answers older ones for a long time.
CLIENT_VERSION :: "1.20261015.01.00"
// Every saved path starts with it, as "youtube/browse?{...}". The JSON after "?" is the request's body.
PATH_PREFIX :: "youtube/"

// Requests wait this long after the app starts for the helper's cookie, then go without a sign-in.
@(private)
COOKIE_WAIT :: 8 * time.Second

@(private)
state: struct {
	mutex:     sync.Mutex,
	cookie:    string,
	has_cookie: bool,
	started:   time.Tick,
}

start :: proc() {
	state.started = time.tick_now()
	apple.add_source(PATH_PREFIX, send_request)
}

// The helper reads the cookie from its YouTube web page at start and after a sign-in. Empty when signed out.
set_cookie :: proc(cookie: string) {
	sync.guard(&state.mutex)
	delete(state.cookie)
	state.cookie = strings.clone(cookie)
	state.has_cookie = true
}

// A cookie without SAPISID belongs to no account.
is_signed_in :: proc() -> bool {
	sync.guard(&state.mutex)

	return find_cookie_value(state.cookie, "SAPISID") != ""
}

// Until the helper has answered, the app cannot tell signed in from signed out.
has_cookie_answer :: proc() -> bool {
	sync.guard(&state.mutex)

	return state.has_cookie
}

HOME_ID :: "FEmusic_home"
LIKED_ID :: "VLLM"
LIBRARY_PLAYLISTS_ID :: "FEmusic_liked_playlists"
PODCAST_EPISODES_ID :: "VLSE"
// The search filters behind YouTube Music's own Songs, Videos and Artists tabs.
SONGS_FILTER :: "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
VIDEOS_FILTER :: "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
ARTISTS_FILTER :: "EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D"

browse_path :: proc(browse_id: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("browseId", browse_id)))
}

search_path :: proc(query, filter: string) -> string {
	return to_path("search", fmt.tprintf("{{%s,%s}}", to_json_field("query", query), to_json_field("params", filter)))
}

// The next part of a long list, which a List names by its continuation.
continuation_path :: proc(token: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("continuation", token)))
}

// The next shelves of a page. YouTube takes this token in the address, as its web player sends it.
section_continuation_path :: proc(token: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("ctoken", token)))
}

// An album, a playlist or the liked songs open by browse ID. A mix or a radio is a playlist ID, such as
// "RDTMAK5uy_…", which only the next endpoint answers.
list_path :: proc(id: string) -> string {
	browse_prefixes := []string{"VL", "MPREb_", "FE", "UC"}
	for prefix in browse_prefixes do if strings.has_prefix(id, prefix) do return browse_path(id)

	return to_path("next", fmt.tprintf("{{%s,\"isAudioOnly\":true}}", to_json_field("playlistId", id)))
}

// Likes the video on the signed-in account, or takes the like back. Blocks. 200 when YouTube took it, 0 signed out.
send_like :: proc(video_id: string, is_liked: bool) -> int {
	if !is_signed_in() do return 0

	endpoint := "like/like" if is_liked else "like/removelike"
	body := fmt.tprintf("{{\"target\":{{%s}}}}", to_json_field("videoId", video_id))

	return send_request(to_path(endpoint, body), context.temp_allocator).status
}

// A path for apple.watch, such as to_path("browse", `{"browseId":"FEmusic_home"}`).
@(private)
to_path :: proc(endpoint, body_json: string) -> string {
	return fmt.tprintf("%s%s?%s", PATH_PREFIX, endpoint, body_json)
}

// Such as `"query":"she's"`, with the value quoted for JSON.
@(private)
to_json_field :: proc(name, value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, `"%s":`, name)
	strings.write_quoted_string(&builder, value)

	return strings.to_string(builder)
}

@(private)
send_request :: proc(path: string, allocator: mem.Allocator) -> apple.Answer {
	for !has_cookie_answer() && time.tick_since(state.started) < COOKIE_WAIT do time.sleep(100 * time.Millisecond)

	endpoint, _, body_json := strings.partition(path[len(PATH_PREFIX):], "?")
	if len(body_json) < 2 do return {}

	section_token := ""
	if strings.has_prefix(body_json, `{"ctoken":`) {
		Section :: struct {
			ctoken: string,
		}
		section: Section
		_ = json.unmarshal_string(body_json, &section, allocator = context.temp_allocator)
		section_token = section.ctoken
		body_json = "{}"
	}

	region := strings.to_upper(apple.STOREFRONT, context.temp_allocator)
	client := fmt.tprintf(`{{"context":{{"client":{{"clientName":"WEB_REMIX","clientVersion":"%s","hl":"en","gl":"%s"}}}}`, CLIENT_VERSION, region)
	// body_json is an object, so its "{" gives way to the context's.
	body := fmt.tprintf("%s,%s", client, body_json[1:]) if len(body_json) > 2 else fmt.tprintf("%s}", client)
	headers := make([dynamic]string, context.temp_allocator)
	append(&headers, "Content-Type: application/json", "Origin: " + ORIGIN, "X-Origin: " + ORIGIN)

	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&state.mutex)
		if api_id := find_cookie_value(state.cookie, "SAPISID"); api_id != "" {
			append(&headers, fmt.tprintf("Cookie: %s", state.cookie), fmt.tprintf("Authorization: %s", to_authorization(api_id)), "X-Goog-AuthUser: 0")
		}
	}

	url := fmt.tprintf("%s%s?prettyPrint=false", BASE_URL, endpoint)
	if section_token != "" {
		url = fmt.tprintf("%s&ctoken=%s&continuation=%s&type=next", url, section_token, section_token)
	}
	response := net.fetch(url, headers[:], context.temp_allocator, .Post, body)
	if response.status != 200 {
		console.add("YouTube", "%s: %s", path, console.to_status_text(response.status))
	}

	return {response.status, strings.clone(string(response.body), allocator)}
}

// The web player signs each request with a SHA-1 of the time, the SAPISID cookie and its origin.
@(private)
to_authorization :: proc(api_id: string) -> string {
	seconds := time.to_unix_seconds(time.now())
	digest: [sha1.DIGEST_SIZE]u8
	context_value: sha1.Context
	sha1.init(&context_value)
	sha1.update(&context_value, transmute([]u8)fmt.tprintf("%d %s %s", seconds, api_id, ORIGIN))
	sha1.final(&context_value, digest[:])

	return fmt.tprintf("SAPISIDHASH %d_%s", seconds, string(hex.encode(digest[:], context.temp_allocator)))
}

@(private)
find_cookie_value :: proc(cookie, name: string) -> string {
	for part in strings.split(cookie, ";", context.temp_allocator) {
		key, _, value := strings.partition(strings.trim_space(part), "=")
		if key == name do return value
	}

	return ""
}
