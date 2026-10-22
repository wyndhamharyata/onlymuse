// The playing song's lyrics: found through Apple's API, read from its TTML.
package lyrics

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:apple"
import "om:platform"
import "om:store"

Word :: struct {
	begin_seconds: f64,
	// The UTF-16 range in the line's text, as CoreText counts.
	utf16_range:   [2]int,
}

// A song timed by line has one word for each line.
Line :: struct {
	begin_seconds:       f64,
	text:                string,
	words:               []Word,
	// Empty when the line reads as written.
	pronunciation:       string,
	pronunciation_words: []Word,
	// The line in English, when Apple has a translation. Empty otherwise.
	translation:         string,
}

Phase :: enum {
	None,
	Loading,
	Ready,
	// Apple has none, or the song is not in the catalog.
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
	// Who wrote the words, as the lyrics name them.
	songwriters:   []string,
	// Holds lines and songwriters.
	arena:         virtual.Arena,
	// The last song's lines, which the frame that asked for the new song may still show.
	last_arena:    virtual.Arena,
}

// The lyrics of the song, loading them the first time it is asked for. Lines live until another song is asked for.
find :: proc(persistent_id, name, artist: string) -> (Phase, []Line) {
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
	// self_cleanup frees the thread when its procedure returns, so nothing waits for it.
	thread.create_and_start_with_data(request, load, self_cleanup = true)

	return state.phase, nil
}

// Runs on a thread of its own.
@(private)
load :: proc(data: rawptr) {
	request := cast(^Request)data
	defer {
		delete(request.persistent_id)
		delete(request.name)
		delete(request.artist)
		free(request)
	}
	defer free_all(context.temp_allocator)

	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	lines, songwriters, ok := fetch_lines(
		request.name,
		request.artist,
		virtual.arena_allocator(&arena),
	)

	sync.guard(&state.mutex)

	// Another song started while these loaded.
	if request.persistent_id != state.persistent_id {
		virtual.arena_destroy(&arena)
		return
	}

	state.phase = .Ready if ok && len(lines) > 0 else .Missing
	state.lines = lines
	state.songwriters = songwriters
	state.arena = arena
	platform.wake()
}

@(private)
LYRICS_QUERY :: "?l%5Blyrics%5D=en-GB&l%5Bscript%5D=en-Latn&extend=ttmlLocalizations"

@(private)
fetch_lines :: proc(name, artist: string, allocator: mem.Allocator) -> ([]Line, []string, bool) {
	song_id, ok := find_song_id(name, artist)
	if !ok do return nil, nil, false

	// A song from YouTube has the ID "yt:" and its video, which Apple's catalog has no lyrics for.
	for character in song_id do if character < '0' || character > '9' do return nil, nil, false

	answer := apple.fetch(
		fmt.tprintf(
			"/v1/catalog/%s/songs/%s/syllable-lyrics%s",
			apple.STOREFRONT,
			song_id,
			LYRICS_QUERY,
		),
		context.temp_allocator,
	)
	is_syllable := answer.status == 200

	// A song with no word timing has only lyrics by line.
	if !is_syllable {
		answer = apple.fetch(
			fmt.tprintf("/v1/catalog/%s/songs/%s/lyrics", apple.STOREFRONT, song_id),
			context.temp_allocator,
		)
	}
	if answer.status != 200 do return nil, nil, false

	Lyrics_Answer :: struct {
		data: []struct {
			attributes: struct {
				ttml:               string,
				ttml_localizations: string `json:"ttmlLocalizations"`,
			},
		},
	}

	parsed: Lyrics_Answer
	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil ||
	   len(parsed.data) == 0 {
		return nil, nil, false
	}

	attributes := parsed.data[0].attributes
	ttml :=
		attributes.ttml_localizations if attributes.ttml_localizations != "" else attributes.ttml

	return to_lines(ttml, allocator), to_songwriters(ttml, allocator), true
}

// The songwriters of the playing song's lyrics, once they have loaded.
find_songwriters :: proc(persistent_id: string) -> []string {
	sync.guard(&state.mutex)

	return state.songwriters if persistent_id == state.persistent_id else nil
}

// A song started outside onlymuse has no catalog ID yet. The queue knows some, the search the rest.
@(private)
find_song_id :: proc(name, artist: string) -> (string, bool) {
	if id, ok := find_queue_song_id(name, artist, context.temp_allocator); ok do return id, true

	term := apple.to_query_text(fmt.tprintf("%s %s", name, artist))
	answer := apple.fetch(
		fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=25", apple.STOREFRONT, term),
		context.temp_allocator,
	)
	if answer.status != 200 do return "", false

	Search_Answer :: struct {
		results: struct {
			songs: struct {
				data: []struct {
					id:         string,
					attributes: struct {
						name:        string,
						artist_name: string `json:"artistName"`,
					},
				},
			},
		},
	}

	parsed: Search_Answer
	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil {
		return "", false
	}

	for song in parsed.results.songs.data {
		if song.attributes.name == name && song.attributes.artist_name == artist {
			return song.id, true
		}
	}

	return "", false
}

// The catalog ID of a song in the saved queue, found by its name and artist.
@(private)
find_queue_song_id :: proc(
	name, artist: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
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
		if song.name == name && song.artist_name == artist {
			return strings.clone(song.id, allocator), true
		}
	}

	return "", false
}
