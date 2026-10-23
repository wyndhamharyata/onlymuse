package youtube

import "core:crypto/legacy/sha1"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "om:apple"
import "om:console"
import "om:net"

BASE_URL :: "https://music.youtube.com/youtubei/v1/"
ORIGIN :: "https://music.youtube.com"
// The web player's own version. YouTube answers older ones for a long time.
CLIENT_VERSION :: "1.20261015.01.00"
PATH_PREFIX :: "youtube/"

@(private)
COOKIE_WAIT :: 8 * time.Second

@(private)
state: struct {
	mutex:             sync.Mutex,
	cookie:            string,
	has_cookie_answer: bool,
	started:           time.Tick,
}

start :: proc() {
	state.started = time.tick_now()
	apple.set_source(PATH_PREFIX, fetch_answer)
}

set_cookie :: proc(cookie: string) {
	sync.guard(&state.mutex)
	delete(state.cookie)
	state.cookie = strings.clone(cookie)
	state.has_cookie_answer = true
}

// A cookie without SAPISID belongs to no account.
is_signed_in :: proc() -> bool {
	sync.guard(&state.mutex)

	return find_cookie_value(state.cookie, "SAPISID") != ""
}

has_cookie_answer :: proc() -> bool {
	sync.guard(&state.mutex)

	return state.has_cookie_answer
}

HOME_ID :: "FEmusic_home"
LIKED_ID :: "VLLM"
LIBRARY_PLAYLISTS_ID :: "FEmusic_liked_playlists"
PODCAST_EPISODES_ID :: "VLSE"
SONGS_FILTER :: "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
VIDEOS_FILTER :: "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
ARTISTS_FILTER :: "EgWKAQIgAWoKEAMQBBAJEAoQBQ%3D%3D"

to_browse_path :: proc(browse_id: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("browseId", browse_id)))
}

to_search_path :: proc(query, filter: string) -> string {
	return to_path(
		"search",
		fmt.tprintf("{{%s,%s}}", to_json_field("query", query), to_json_field("params", filter)),
	)
}

to_continuation_path :: proc(token: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("continuation", token)))
}

// The next shelves of a page. YouTube takes this token in the address, as its web player sends it.
to_section_continuation_path :: proc(token: string) -> string {
	return to_path("browse", fmt.tprintf("{{%s}}", to_json_field("ctoken", token)))
}

// A mix or radio has a playlist ID, such as "RDTMAK5uy_…", that only the next endpoint answers.
to_list_path :: proc(id: string) -> string {
	browse_prefixes := []string{"VL", "MPREb_", "FE", "UC"}
	for prefix in browse_prefixes do if strings.has_prefix(id, prefix) do return to_browse_path(id)

	return to_path(
		"next",
		fmt.tprintf("{{%s,\"isAudioOnly\":true}}", to_json_field("playlistId", id)),
	)
}

post_like :: proc(video_id: string, is_liked: bool) -> int {
	if !is_signed_in() do return 0

	endpoint := "like/like" if is_liked else "like/removelike"
	body := fmt.tprintf("{{\"target\":{{%s}}}}", to_json_field("videoId", video_id))

	return fetch_answer(to_path(endpoint, body), context.temp_allocator).status
}

@(private)
to_path :: proc(endpoint, body_json: string) -> string {
	return fmt.tprintf("%s%s?%s", PATH_PREFIX, endpoint, body_json)
}

@(private)
to_json_field :: proc(name, value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, `"%s":`, name)
	io.write_quoted_string(strings.to_writer(&builder), value, for_json = true)

	return strings.to_string(builder)
}

@(private)
fetch_answer :: proc(path: string, allocator: mem.Allocator) -> apple.Answer {
	for !has_cookie_answer() && time.tick_since(state.started) < COOKIE_WAIT {
		time.sleep(100 * time.Millisecond)
	}

	endpoint, _, body_json := strings.partition(path[len(PATH_PREFIX):], "?")
	if len(body_json) < len("{}") do return {}

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
	client := fmt.tprintf(
		`{{"context":{{"client":{{"clientName":"WEB_REMIX","clientVersion":"%s","hl":"en","gl":"%s"}}}}`,
		CLIENT_VERSION,
		region,
	)
	body :=
		fmt.tprintf("%s,%s", client, body_json[1:]) if body_json != "{}" else fmt.tprintf("%s}", client)

	headers := make([dynamic]string, context.temp_allocator)
	append(&headers, "Content-Type: application/json", "Origin: " + ORIGIN, "X-Origin: " + ORIGIN)

	{
		sync.guard(&state.mutex)

		if api_id := find_cookie_value(state.cookie, "SAPISID"); api_id != "" {
			append(
				&headers,
				fmt.tprintf("Cookie: %s", state.cookie),
				fmt.tprintf("Authorization: %s", to_authorization(api_id)),
				"X-Goog-AuthUser: 0",
			)
		}
	}

	url := fmt.tprintf("%s%s?prettyPrint=false", BASE_URL, endpoint)

	if section_token != "" {
		url = fmt.tprintf(
			"%s&ctoken=%s&continuation=%s&type=next",
			url,
			section_token,
			section_token,
		)
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

	return fmt.tprintf(
		"SAPISIDHASH %d_%s",
		seconds,
		string(hex.encode(digest[:], context.temp_allocator)),
	)
}

@(private)
find_cookie_value :: proc(cookie, name: string) -> string {
	for part in strings.split(cookie, ";", context.temp_allocator) {
		key, _, value := strings.partition(strings.trim_space(part), "=")
		if key == name do return value
	}

	return ""
}
