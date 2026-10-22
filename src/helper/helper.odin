// The Swift helper in ../helper, which controls Music.app. It speaks JSON lines over stdin and stdout.
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
	artist:           string,
	album:            string,
	persistent_id:    string `json:"persistentID"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	// Music.app's artwork, saved by the helper.
	artwork_path:     string `json:"artworkPath"`,
}

// Each message the helper sends, as send() in helper/Sources/onlymuse-helper names it. Fields a type lacks stay empty.
Message :: struct {
	type:                string,
	state:               string,
	volume_percent:      f64 `json:"volumePercent"`,
	position_seconds:    f64 `json:"positionSeconds"`,
	position_read_at_ms: f64 `json:"positionReadAtMs"`,
	persistent_id:       string `json:"persistentID"`,
	song:                Song,
	// nowPlaying from the YouTube page: is_loading while it loads the song, has_started once it plays it.
	is_loading:          bool `json:"isLoading"`,
	has_started:         bool `json:"hasStarted"`,
	color:               string,
	developer_token:     string `json:"developerToken"`,
	user_token:          string `json:"userToken"`,
	text:                string,
	// youtubeCookie: Helium's youtube.com cookies, empty when signed out. problem says why there are none:
	// "keychain" when the Keychain refused the key, "helium" when Helium's cookies could not be read.
	cookie:              string,
	problem:             string,
	request_id:          int `json:"requestId"`,
	// trackInfo: what Music.app knows of a song. Dates are Unix ms, 0 when it has none.
	is_in_library:       bool `json:"isInLibrary"`,
	favorited:           bool,
	played_count:        int `json:"playedCount"`,
	played_date_ms:      f64 `json:"playedDateMs"`,
	skipped_count:       int `json:"skippedCount"`,
	skipped_date_ms:     f64 `json:"skippedDateMs"`,
	date_added_ms:       f64 `json:"dateAddedMs"`,
	bit_rate:            int `json:"bitRate"`,
	sample_rate:         int `json:"sampleRate"`,
	kind:                string,
	bpm:                 int,
	size:                f64,
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
	// Unix time in ms when the helper read the position.
	position_read_at_ms: f64,
	// Positions in a row that had not moved on while Music.app said it played. Music.app does that while it
	// waits for a song it cannot load, and the clock then stays still.
	stall_count:         int,
	// The position has moved since the song began. Music.app says it plays a song while it still loads it.
	has_started:         bool,
	// The YouTube page loads the song and plays nothing yet. Music.app is paused by then.
	is_loading:          bool,
}

// A position this far past the last one has moved on. The helper sends one every 2 s.
MIN_PROGRESS_SECONDS :: 0.5

@(private)
state: struct {
	process:     os.Process,
	to_helper:   ^os.File,
	from_helper: ^os.File,
	reader:      ^thread.Thread,
	mutex:       sync.Mutex,
	write_mutex: sync.Mutex,
	// Lines read and not yet taken by the main thread.
	lines:       [dynamic]string,
	is_started:  bool,
}

// OM_HELPER names a stand-in for the tests. GPUIX_BACKGROUND=1 tells the helper to leave Music.app as it is when the app quits.
start :: proc(is_background: bool) {
	path := os.get_env("OM_HELPER", context.temp_allocator)

	if path == "" {
		executable_folder, _ := os.get_executable_directory(context.temp_allocator)
		// onlymuse.app holds the helper in Contents/Helpers. build/onlymuse runs the one SwiftPM built.
		bundled := fmt.tprintf("%s/../Helpers/onlymuse-helper", executable_folder)
		path =
			bundled if os.exists(bundled) else fmt.tprintf("%s/../helper/.build/release/onlymuse-helper", executable_folder)
	}

	// A write to a helper that has ended then fails, instead of ending onlymuse.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

	child_stdin, to_helper, _ := os.pipe()
	from_helper, child_stdout, _ := os.pipe()
	environment, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..environment)
	if is_background do append(&env, "GPUIX_BACKGROUND=1")

	process, error := os.process_start(
		{
			command = {path},
			env = env[:],
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

// The messages since the last call. They live until the next frame.
take_messages :: proc() -> []Message {
	lines: [dynamic]string
	// sync.guard unlocks when its block ends, so these braces end the lock.
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

// Takes in one message from the helper.
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
		now_playing.position_read_at_ms =
			min(message.position_read_at_ms, now_ms()) if message.position_read_at_ms > 0 else now_ms()
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
		now_playing.position_read_at_ms = min(message.position_read_at_ms, now_ms())
	}
}

@(private)
delete_song :: proc(song: Song) {
	delete(song.name)
	delete(song.artist)
	delete(song.album)
	delete(song.persistent_id)
	delete(song.artwork_path)
}

@(private)
clone_song :: proc(song: Song) -> Song {
	return Song {
		name = strings.clone(song.name),
		artist = strings.clone(song.artist),
		album = strings.clone(song.album),
		persistent_id = strings.clone(song.persistent_id),
		artwork_path = strings.clone(song.artwork_path),
		duration_seconds = song.duration_seconds,
	}
}

now_ms :: proc() -> f64 {
	return f64(time.to_unix_nanoseconds(time.now())) / 1e6
}

// Music.app posts only on a change, so the position moves on here between its posts.
position_seconds :: proc(now_playing: Now_Playing) -> f64 {
	#partial switch now_playing.playback {
	case .Paused:
		return now_playing.position_seconds
	case .Playing:
		if now_playing.stall_count > 0 || !now_playing.has_started {
			return now_playing.position_seconds
		}
		elapsed_seconds := max(0, now_ms() - now_playing.position_read_at_ms) / 1000
		return min(
			now_playing.position_seconds + elapsed_seconds,
			now_playing.song.duration_seconds,
		)
	}

	return 0
}
