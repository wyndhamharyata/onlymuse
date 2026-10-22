package helper

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"

// What the helper needs to find a catalog song in Music.app's library.
Song_Match :: struct {
	name:             string,
	artist_name:      string `json:"artistName"`,
	album_name:       string `json:"albumName"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	// Set for a song that plays from YouTube, in the helper's YouTube page.
	youtube_id:       string `json:"youtubeId"`,
}

@(private)
last_request_id: int

// Asks the helper to play the song. Its answer, playSongResult, carries the returned ID and the song's
// persistent ID, empty when the song is not in Music.app's library.
request_play :: proc(song: Song_Match) -> int {
	last_request_id += 1
	Command :: struct {
		type:       string,
		request_id: int `json:"requestId"`,
		song:       Song_Match,
	}
	send_value(Command{"playSong", last_request_id, song})

	return last_request_id
}

// The helper starts song just before after_persistent_id ends, so Music.app's Autoplay never plays.
// An empty after_persistent_id clears it. Its answer is setNextResult. keeps_youtube keeps the helper's YouTube
// page open, as a YouTube song plays later.
request_set_next :: proc(
	after_persistent_id: string,
	song: Maybe(Song_Match),
	keeps_youtube: bool,
) -> int {
	last_request_id += 1
	after := after_persistent_id if after_persistent_id != "" else "null"
	song_json := "null"
	if match, ok := song.?; ok {
		bytes, _ := json.marshal(match, allocator = context.temp_allocator)
		song_json = string(bytes)
	}
	after_json :=
		fmt.tprintf("\"%s\"", after_persistent_id) if after_persistent_id != "" else after
	send(
		fmt.tprintf(
			`{{"type":"setNext","requestId":%d,"afterPersistentID":%s,"song":%s,"keepsYouTube":%v}}`,
			last_request_id,
			after_json,
			song_json,
			keeps_youtube,
		),
	)

	return last_request_id
}

// What Music.app knows of a song: plays, dates, favourite and file. Its answer is trackInfo.
request_track_info :: proc(persistent_id: string) {
	Command :: struct {
		type:          string,
		persistent_id: string `json:"persistentID"`,
	}
	send_value(Command{"trackInfo", persistent_id})
}

// By persistent ID when the song is the playing one or known, else by a match in the library.
// Its answer is setFavoriteResult, with a null persistent ID when Music.app found no such song.
request_set_favorite :: proc(persistent_id: string, song: Song_Match, favorited: bool) -> int {
	last_request_id += 1
	Command :: struct {
		type:          string,
		request_id:    int `json:"requestId"`,
		persistent_id: string `json:"persistentID"`,
		song:          Song_Match,
		favorited:     bool,
	}
	send_value(Command{"setFavorite", last_request_id, persistent_id, song, favorited})

	return last_request_id
}

send_value :: proc(value: $T) {
	bytes, error := json.marshal(value, allocator = context.temp_allocator)
	if error == nil do send(string(bytes))
}

// Each command the helper reads, as Command in helper/Sources/onlymuse-helper/Link.swift names it.
send :: proc(command: string) {
	if !state.is_started do return

	// Workers send too, and one line must never break into another.
	sync.guard(&state.write_mutex)
	line := fmt.tprintf("%s\n", command)
	os.write(state.to_helper, transmute([]u8)line)
}
