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
	// Only a song that plays from YouTube, in the helper's YouTube page, has a youtube_id.
	youtube_id:       string `json:"youtubeId"`,
}

// @(private) keeps a declaration inside the helper package.
@(private)
last_request_id: int

// Asks the helper to play the song. Its answer, playSongResult, holds the returned ID and the
// song's persistent ID, which stays empty when the song is not in Music.app's library.
send_play :: proc(song: Song_Match) -> int {
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
// An empty after_persistent_id cancels the next song. The answer is setNextResult.
send_set_next :: proc(
	after_persistent_id: string,
	song: Maybe(Song_Match),
	// true keeps the helper's YouTube page open, as a YouTube song plays later.
	keeps_youtube: bool,
) -> int {
	last_request_id += 1

	after := after_persistent_id if after_persistent_id != "" else "null"
	song_json := "null"

	// song.? takes the value out of the Maybe. ok is false when the caller passed nil.
	if match, ok := song.?; ok {
		// context.temp_allocator belongs to the calling thread, which frees it after this call.
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

// Asks what Music.app knows of a song: plays, dates, favourite and file. The answer is trackInfo.
send_song_info_request :: proc(persistent_id: string) {
	Command :: struct {
		type:          string,
		persistent_id: string `json:"persistentID"`,
	}

	send_value(Command{"trackInfo", persistent_id})
}

// The helper finds the playing song or a song it knows by persistent_id, any other by song.
// Its answer is setFavoriteResult, with a null persistent ID when Music.app found no such song.
send_set_favorite :: proc(persistent_id: string, song: Song_Match, favorited: bool) -> int {
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

// $T lets send_value take a value of any type.
send_value :: proc(value: $T) {
	bytes, error := json.marshal(value, allocator = context.temp_allocator)
	if error == nil do send(string(bytes))
}

// send writes one command for the helper.
// Command in helper/Sources/onlymuse-helper/Link.swift names each command the helper reads.
send :: proc(command: string) {
	if !state.is_started do return

	// Worker threads send too. One line must never break into another.
	// sync.guard holds write_mutex until send returns.
	sync.guard(&state.write_mutex)
	line := fmt.tprintf("%s\n", command)
	// transmute reads the string's bytes as []u8 with no copy.
	os.write(state.to_helper, transmute([]u8)line)
}
