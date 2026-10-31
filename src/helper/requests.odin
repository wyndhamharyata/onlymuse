package helper

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"

APPLE_WEB_PREFIX :: "am:"

Song_Match :: struct {
	name:             string,
	artist_name:      string `json:"artistName"`,
	album_name:       string `json:"albumName"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	apple_id:         string `json:"appleId"`,
	youtube_id:       string `json:"youtubeId"`,
}

@(private)
last_request_id: int

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
send_set_next :: proc(
	after_persistent_id: string,
	song: Maybe(Song_Match),
	is_youtube_next: bool,
) -> int {
	last_request_id += 1

	Command :: struct {
		type:                string,
		request_id:          int `json:"requestId"`,
		after_persistent_id: Maybe(string) `json:"afterPersistentID"`,
		song:                Maybe(Song_Match),
		is_youtube_next:     bool `json:"keepsYouTube"`,
	}

	after: Maybe(string)
	if after_persistent_id != "" do after = after_persistent_id

	send_value(Command{"setNext", last_request_id, after, song, is_youtube_next})

	return last_request_id
}

send_set_player :: proc(is_driving_music_app: bool) {
	Command :: struct {
		type:                 string,
		is_driving_music_app: bool `json:"drivesMusicApp"`,
	}

	send_value(Command{"setPlayer", is_driving_music_app})
}

send_song_info_request :: proc(persistent_id: string) {
	Command :: struct {
		type:          string,
		persistent_id: string `json:"persistentID"`,
	}

	send_value(Command{"songInfo", persistent_id})
}

send_set_favorite :: proc(persistent_id: string, song: Song_Match, is_favourite: bool) -> int {
	last_request_id += 1

	Command :: struct {
		type:          string,
		request_id:    int `json:"requestId"`,
		persistent_id: Maybe(string) `json:"persistentID"`,
		song:          Song_Match,
		is_favourite:  bool `json:"favorited"`,
	}

	known_id: Maybe(string)
	if persistent_id != "" do known_id = persistent_id

	send_value(Command{"setFavorite", last_request_id, known_id, song, is_favourite})

	return last_request_id
}

send_play_pause :: proc() {
	send(`{"type":"playPause"}`)
}

send_next :: proc() {
	send(`{"type":"next"}`)
}

send_previous :: proc() {
	send(`{"type":"previous"}`)
}

send_seek :: proc(position_seconds: f64) {
	Command :: struct {
		type:             string,
		position_seconds: f64 `json:"positionSeconds"`,
	}

	send_value(Command{"seek", position_seconds})
}

send_set_volume :: proc(volume_percent: int) {
	Command :: struct {
		type:           string,
		volume_percent: int `json:"volumePercent"`,
	}

	send_value(Command{"setVolume", volume_percent})
}

send_refresh_tokens :: proc() {
	send(`{"type":"refreshTokens"}`)
}

send_sign_in :: proc() {
	send(`{"type":"signIn"}`)
}

send_youtube_sign_in :: proc() {
	send(`{"type":"youtubeSignIn"}`)
}

@(private)
send_value :: proc(value: $T) {
	bytes, error := json.marshal(value, allocator = context.temp_allocator)
	if error == nil do send(string(bytes))
}

@(private)
send :: proc(command: string) {
	if !state.is_started do return

	// Worker threads send too. One line must never break into another.
	sync.guard(&state.write_mutex)
	line := fmt.tprintf("%s\n", command)
	os.write(state.to_helper, transmute([]u8)line)
}
