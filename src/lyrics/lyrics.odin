package lyrics

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:apple"
import "om:net"
import "om:platform"
import "om:store"

Word :: struct {
	begin_seconds: f64,
	utf16_range:   [2]int,
}

Line :: struct {
	begin_seconds:       f64,
	text:                string,
	words:               []Word,
	pronunciation:       string,
	pronunciation_words: []Word,
	translation:         string,
}

Phase :: enum {
	None,
	Loading,
	Ready,
	Missing,
}

@(private)
Request :: struct {
	persistent_id: string,
	name:          string,
	artist:        string,
}

@(private)
state: struct {
	mutex:         sync.Mutex,
	persistent_id: string,
	phase:         Phase,
	lines:         []Line,
	songwriters:   []string,
	arena:         virtual.Arena,
	last_arena:    virtual.Arena,
}

watch :: proc(persistent_id, name, artist: string) -> (Phase, []Line) {
	sync.guard(&state.mutex)

	if persistent_id == state.persistent_id do return state.phase, state.lines

	delete(state.persistent_id)
	state.persistent_id = strings.clone(persistent_id)
	state.phase = .Loading
	state.lines = nil
	state.songwriters = nil

	virtual.arena_destroy(&state.last_arena)
	state.last_arena = state.arena
	state.arena = {}

	request := new(Request)
	request^ = {strings.clone(persistent_id), strings.clone(name), strings.clone(artist)}
	thread.create_and_start_with_data(request, fetch_lyrics, self_cleanup = true)

	return state.phase, nil
}

@(private)
fetch_lyrics :: proc(data: rawptr) {
	request := cast(^Request)data

	defer net.stop_thread()
	defer {
		delete(request.persistent_id)
		delete(request.name)
		delete(request.artist)
		free(request)
	}
	defer free_all(context.temp_allocator)

	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)

	lines, songwriters := fetch_lines(
		request.name,
		request.artist,
		virtual.arena_allocator(&arena),
	)

	sync.guard(&state.mutex)

	if request.persistent_id != state.persistent_id {
		virtual.arena_destroy(&arena)
		return
	}

	state.phase = .Ready if len(lines) > 0 else .Missing
	state.lines = lines
	state.songwriters = songwriters
	state.arena = arena
	platform.wake()
}

// "%5B" and "%5D" encode "[" and "]". The query asks for English translations and Latin letters.
@(private)
LYRICS_QUERY ::
	"?l%5Blyrics%5D=" + apple.LANGUAGE + "&l%5Bscript%5D=en-Latn&extend=ttmlLocalizations"

@(private)
fetch_lines :: proc(name, artist: string, allocator: mem.Allocator) -> ([]Line, []string) {
	song_id, ok := find_song_id(name, artist)
	if !ok do return nil, nil

	// Only a catalog ID is all digits. A YouTube or library ID has no lyrics.
	for character in song_id do if character < '0' || character > '9' do return nil, nil

	answer := apple.fetch(
		fmt.tprintf(
			"/v1/catalog/%s/songs/%s/syllable-lyrics%s",
			apple.STOREFRONT,
			song_id,
			LYRICS_QUERY,
		),
	)
	is_syllable := answer.status == 200

	if !is_syllable {
		answer = apple.fetch(
			fmt.tprintf("/v1/catalog/%s/songs/%s/lyrics", apple.STOREFRONT, song_id),
		)
	}

	if answer.status != 200 do return nil, nil

	Lyrics_Answer :: struct {
		data: []struct {
			attributes: struct {
				ttml:               string,
				ttml_localizations: string `json:"ttmlLocalizations"`,
			},
		},
	}

	parsed: Lyrics_Answer

	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil {
		return nil, nil
	}
	if len(parsed.data) == 0 do return nil, nil

	attributes := parsed.data[0].attributes
	ttml :=
		attributes.ttml_localizations if attributes.ttml_localizations != "" else attributes.ttml

	return to_lines(ttml, allocator), to_songwriters(ttml, allocator)
}

list_songwriters :: proc(persistent_id: string) -> []string {
	sync.guard(&state.mutex)

	return state.songwriters if persistent_id == state.persistent_id else nil
}

// A song started outside onlymuse has no catalog ID, so the saved queue or a search finds it.
@(private)
find_song_id :: proc(name, artist: string) -> (string, bool) {
	if id, ok := find_queue_song_id(name, artist); ok do return id, true

	term := apple.to_query_text(fmt.tprintf("%s %s", name, artist))
	answer := apple.fetch(
		fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=25", apple.STOREFRONT, term),
	)
	if answer.status != 200 do return "", false

	parsed: apple.Search_Answer

	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil {
		return "", false
	}

	for song in parsed.results.songs.data {
		if is_same_song(song.attributes.name, song.attributes.artist_name, name, artist) {
			return song.id, true
		}
	}

	return "", false
}

@(private)
find_queue_song_id :: proc(name, artist: string) -> (string, bool) {
	Queue :: struct {
		songs: []struct {
			id:          string,
			name:        string,
			artist_name: string `json:"artistName"`,
		},
	}

	text, ok := store.find_state("queue", context.temp_allocator)
	if !ok do return "", false

	queue: Queue

	if json.unmarshal_string(text, &queue, allocator = context.temp_allocator) != nil {
		return "", false
	}

	for song in queue.songs {
		if is_same_song(song.name, song.artist_name, name, artist) {
			return song.id, true
		}
	}

	return "", false
}

@(private)
is_same_song :: proc(name, artist, playing_name, playing_artist: string) -> bool {
	return name == playing_name && artist == playing_artist
}
