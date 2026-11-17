package youtube

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:net"

Caption_Track :: struct {
	language_code: string `json:"languageCode"`,
	kind:          string,
	base_url:      string `json:"baseUrl"`,
}

Caption_Tracklist :: struct {
	caption_tracks: []Caption_Track `json:"captionTracks"`,
}

@(private)
PLAYER_URL :: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"

@(private)
PLAYER_BODY :: `{{"context":{{"client":{{"clientName":"ANDROID","clientVersion":"20.10.38","androidSdkVersion":30,"hl":"en","gl":"US"}}}},"videoId":"%s"}}`

Player_Answer :: struct {
	captions: struct {
		tracklist: Caption_Tracklist `json:"playerCaptionsTracklistRenderer"`,
	} `json:"captions"`,
}

// Reads the caption text a person wrote for the video, timed to the video itself. The WEB_REMIX
// client needs the signed-in page, the ANDROID one answers without it. An empty string means the
// video has no written track in its own language.
read_caption_text :: proc(video_id: string) -> string {
	body := fmt.tprintf(PLAYER_BODY, video_id)
	answer := net.fetch(PLAYER_URL, []string{"Content-Type: application/json"}, .Post, body)
	if answer.status != 200 do return ""

	parsed: Player_Answer
	if json.unmarshal_string(string(answer.body), &parsed, allocator = context.temp_allocator) !=
	   nil {
		return ""
	}

	tracklist := parsed.captions.tracklist
	original_language := find_original_caption_language(tracklist.caption_tracks)

	for track in tracklist.caption_tracks {
		if track.kind == "asr" do continue
		if !is_same_caption_language(track.language_code, original_language) do continue

		text := net.fetch(track.base_url)
		return string(text.body) if text.status == 200 else ""
	}

	return ""
}

// YouTube marks the tracks it writes itself with kind "asr". An asr track comes from the video's
// own audio, so it names the original language. Only that language tells which written track holds
// the song's own text rather than a translation.
@(private)
find_original_caption_language :: proc(tracks: []Caption_Track) -> string {
	for track in tracks {
		if track.kind == "asr" do return track.language_code
	}

	return ""
}

@(private)
is_same_caption_language :: proc(track_language, original_language: string) -> bool {
	if original_language == "" do return false

	track_base, _, _ := strings.partition(track_language, "-")
	original_base, _, _ := strings.partition(original_language, "-")
	return track_base == original_base
}
