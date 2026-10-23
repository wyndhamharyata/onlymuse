package helper

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "om:console"
import "om:platform"

Song :: struct {
	name:             string,
	artist_name:      string `json:"artist"`,
	album_name:       string `json:"album"`,
	persistent_id:    string `json:"persistentID"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	artwork_path:     string `json:"artworkPath"`,
}

Message :: struct {
	type:                string,
	state:               string,
	volume_percent:      f64 `json:"volumePercent"`,
	position_seconds:    f64 `json:"positionSeconds"`,
	position_read_at_ms: f64 `json:"positionReadAtMs"`,
	persistent_id:       string `json:"persistentID"`,
	song:                Song,
	is_loading:          bool `json:"isLoading"`,
	has_started:         bool `json:"hasStarted"`,
	color:               string,
	developer_token:     string `json:"developerToken"`,
	user_token:          string `json:"userToken"`,
	text:                string,
	cookie:              string,
	problem:             string,
	request_id:          int `json:"requestId"`,
	is_in_library:       bool `json:"isInLibrary"`,
	is_favourite:        bool `json:"favorited"`,
	played_count:        int `json:"playedCount"`,
	played_date_ms:      f64 `json:"playedDateMs"`,
	skipped_count:       int `json:"skippedCount"`,
	skipped_date_ms:     f64 `json:"skippedDateMs"`,
	date_added_ms:       f64 `json:"dateAddedMs"`,
	bit_rate_kbps:       int `json:"bitRate"`,
	sample_rate_hz:      int `json:"sampleRate"`,
	kind:                string,
	bpm:                 int,
	size_bytes:          f64 `json:"size"`,
}

Playback :: enum {
	Closed,
	Stopped,
	Playing,
	Paused,
}

Now_Playing :: struct {
	playback:            Playback,
	volume_percent:      f64,
	song:                Song,
	position_seconds:    f64,
	position_read_at_ms: f64,
	// Music.app says it plays while it waits for a song it cannot load. The position stays still.
	stall_count:         int,
	has_started:         bool,
	is_loading:          bool,
}

// A position this far past the last one counts as moved on. The helper sends one every 2 s.
@(private)
MIN_PROGRESS_SECONDS :: 0.5

@(private)
state: struct {
	process:     os.Process,
	to_helper:   ^os.File,
	from_helper: ^os.File,
	reader:      ^thread.Thread,
	mutex:       sync.Mutex,
	write_mutex: sync.Mutex,
	lines:       [dynamic]string,
	is_started:  bool,
}

start :: proc(is_background: bool) {
	path := os.get_env("OM_HELPER", context.temp_allocator)

	if path == "" {
		executable_folder, _ := os.get_executable_directory(context.temp_allocator)
		bundled := fmt.tprintf("%s/../Helpers/onlymuse-helper", executable_folder)
		path =
			bundled if os.exists(bundled) else fmt.tprintf("%s/../helper/.build/release/onlymuse-helper", executable_folder)
	}

	// With SIGPIPE ignored, a write to a helper that ended fails and onlymuse keeps running.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	child_stdin, to_helper, _ := os.pipe()
	from_helper, child_stdout, _ := os.pipe()

	environment, _ := os.environ(context.temp_allocator)
	child_environment := make([dynamic]string, context.temp_allocator)
	append(&child_environment, ..environment)
	if is_background do append(&child_environment, "GPUIX_BACKGROUND=1")

	process, error := os.process_start(
		{
			command = {path},
			env = child_environment[:],
			stdin = child_stdin,
			stdout = child_stdout,
			stderr = os.stderr,
		},
	)
	os.close(child_stdin)
	os.close(child_stdout)

	if error != nil {
		console.add("Helper", "Cannot start %s: %v", path, error)
		return
	}

	state.process = process
	state.to_helper = to_helper
	state.from_helper = from_helper
	state.is_started = true
	state.reader = thread.create_and_start(read_lines)
}

@(private)
read_lines :: proc() {
	buffer: [64 * 1024]u8
	pending := make([dynamic]u8)

	for {
		count, error := os.read(state.from_helper, buffer[:])
		if count <= 0 || error != nil do break

		append(&pending, ..buffer[:count])

		for {
			index := strings.index_byte(string(pending[:]), '\n')
			if index < 0 do break

			line := strings.clone(string(pending[:index]))
			remove_range(&pending, 0, index + 1)
			sync.guard(&state.mutex)
			append(&state.lines, line)
		}

		platform.wake()
	}

	console.add("Helper", "The helper stopped. Quit onlymuse and open it again.")
}

take_messages :: proc() -> []Message {
	lines: [dynamic]string

	{
		sync.guard(&state.mutex)
		lines = state.lines
		state.lines = {}
	}

	defer {
		for line in lines do delete(line)
		delete(lines)
	}

	messages := make([dynamic]Message, context.temp_allocator)

	for line in lines {
		message: Message

		if json.unmarshal_string(line, &message, allocator = context.temp_allocator) != nil {
			continue
		}

		append(&messages, message)
	}

	return messages[:]
}

apply :: proc(now_playing: ^Now_Playing, message: Message) {
	switch message.type {
	case "volume":
		now_playing.volume_percent = message.volume_percent
	case "nowPlaying":
		now_playing.volume_percent = message.volume_percent

		switch message.state {
		case "playing":
			now_playing.playback = .Playing
		case "paused":
			now_playing.playback = .Paused
		case "stopped":
			now_playing.playback = .Stopped
		case:
			now_playing.playback = .Closed
		}

		delete_song(now_playing.song)
		now_playing.song = clone_song(message.song)

		now_playing.position_seconds = message.position_seconds
		now_playing.position_read_at_ms = to_read_at_ms(message, now_ms())
		now_playing.stall_count = 0
		now_playing.has_started =
			message.has_started || message.position_seconds >= MIN_PROGRESS_SECONDS
		now_playing.is_loading = message.is_loading
	case "position":
		is_same_song :=
			now_playing.playback == .Playing &&
			now_playing.song.persistent_id == message.persistent_id
		if !is_same_song do return

		has_moved := message.position_seconds > now_playing.position_seconds + MIN_PROGRESS_SECONDS
		now_playing.stall_count = 0 if has_moved else now_playing.stall_count + 1
		if has_moved do now_playing.has_started = true
		now_playing.position_seconds = message.position_seconds
		now_playing.position_read_at_ms = to_read_at_ms(message, now_ms())
	}
}

@(private)
to_read_at_ms :: proc(message: Message, now_ms: f64) -> f64 {
	return min(message.position_read_at_ms, now_ms) if message.position_read_at_ms > 0 else now_ms
}

@(private)
delete_song :: proc(song: Song) {
	delete(song.name)
	delete(song.artist_name)
	delete(song.album_name)
	delete(song.persistent_id)
	delete(song.artwork_path)
}

@(private)
clone_song :: proc(song: Song) -> Song {
	return Song {
		name = strings.clone(song.name),
		artist_name = strings.clone(song.artist_name),
		album_name = strings.clone(song.album_name),
		persistent_id = strings.clone(song.persistent_id),
		artwork_path = strings.clone(song.artwork_path),
		duration_seconds = song.duration_seconds,
	}
}

now_ms :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e6
}

has_song :: proc(now_playing: Now_Playing) -> bool {
	return now_playing.playback == .Playing || now_playing.playback == .Paused
}

// Music.app posts only on a change, so the position moves on here between its posts.
read_position_seconds :: proc(now_playing: Now_Playing) -> f64 {
	#partial switch now_playing.playback {
	case .Paused:
		return now_playing.position_seconds
	case .Playing:
		is_clock_stopped := now_playing.stall_count > 0 || !now_playing.has_started
		if is_clock_stopped do return now_playing.position_seconds

		elapsed_seconds := max(0, now_ms() - now_playing.position_read_at_ms) / 1000
		return min(
			now_playing.position_seconds + elapsed_seconds,
			now_playing.song.duration_seconds,
		)
	}

	return 0
}
