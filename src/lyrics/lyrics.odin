// The playing song's lyrics: found through Apple's API, read from its TTML.
package lyrics

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
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
	lines, songwriters, ok := fetch_lines(request.name, request.artist, virtual.arena_allocator(&arena))

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

	answer := apple.fetch(fmt.tprintf("/v1/catalog/%s/songs/%s/syllable-lyrics%s", apple.STOREFRONT, song_id, LYRICS_QUERY), context.temp_allocator)
	is_syllable := answer.status == 200

	// A song with no word timing has only lyrics by line.
	if !is_syllable do answer = apple.fetch(fmt.tprintf("/v1/catalog/%s/songs/%s/lyrics", apple.STOREFRONT, song_id), context.temp_allocator)
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
	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil || len(parsed.data) == 0 do return nil, nil, false

	attributes := parsed.data[0].attributes
	ttml := attributes.ttml_localizations if attributes.ttml_localizations != "" else attributes.ttml

	return to_lines(ttml, allocator), to_songwriters(ttml, allocator), true
}

// The songwriters of the playing song's lyrics, once they have loaded.
find_songwriters :: proc(persistent_id: string) -> []string {
	sync.guard(&state.mutex)

	return state.songwriters if persistent_id == state.persistent_id else nil
}

@(private)
to_songwriters :: proc(ttml: string, allocator: mem.Allocator) -> []string {
	names := make([dynamic]string, allocator)
	rest := ttml

	for {
		start := strings.index(rest, "<songwriter>")
		if start < 0 do break

		rest = rest[start + len("<songwriter>"):]
		end := strings.index(rest, "</songwriter>")
		if end < 0 do break

		append(&names, strings.clone(to_plain_text(rest[:end]), allocator))
		rest = rest[end:]
	}

	return names[:]
}

// A song started outside onlymuse has no catalog ID yet. The queue knows some, the search the rest.
@(private)
find_song_id :: proc(name, artist: string) -> (string, bool) {
	if id, ok := find_queue_song_id(name, artist, context.temp_allocator); ok do return id, true

	term := apple.to_query_text(fmt.tprintf("%s %s", name, artist))
	answer := apple.fetch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs&limit=25", apple.STOREFRONT, term), context.temp_allocator)
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
	if json.unmarshal_string(answer.body, &parsed, allocator = context.temp_allocator) != nil do return "", false

	for song in parsed.results.songs.data {
		if song.attributes.name == name && song.attributes.artist_name == artist do return song.id, true
	}

	return "", false
}

// TTML writes a time as seconds, as "3:22.434", or as "1:03:22.434".
@(private)
to_seconds :: proc(text: string) -> f64 {
	total: f64

	for part in strings.split(text, ":", context.temp_allocator) {
		total = total * 60 + (strconv.parse_f64(part) or_else 0)
	}

	return total
}

@(private)
to_plain_text :: proc(markup: string) -> string {
	text := markup
	entities := [][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&apos;", "'"}, {"&quot;", "\""}, {"&amp;", "&"}}

	for entity in entities do text, _ = strings.replace_all(text, entity[0], entity[1], context.temp_allocator)

	return text
}

// The value of name="..." in the attributes of a tag.
@(private)
find_attribute :: proc(attributes, name: string) -> string {
	marker := fmt.tprintf("%s=\"", name)
	start := strings.index(attributes, marker)
	if start < 0 do return ""

	rest := attributes[start + len(marker):]
	end := strings.index_byte(rest, '"')

	return rest[:end] if end >= 0 else ""
}

@(private)
utf16_length :: proc(text: string) -> int {
	count := 0
	for character in text do count += 2 if character >= 0x10000 else 1

	return count
}

// A word is a span with its own start. The space after it stays with it, so the words join back into the line.
@(private)
to_words :: proc(markup: string, line_begin_seconds: f64, allocator: mem.Allocator) -> (text: string, words: []Word) {
	builder := strings.builder_make(allocator)
	word_list := make([dynamic]Word, allocator)
	utf16_index := 0
	rest := markup

	for {
		start := strings.index(rest, "<span begin=\"")
		if start < 0 do break

		rest = rest[start:]
		tag_end := strings.index_byte(rest, '>')
		if tag_end < 0 do break

		begin := find_attribute(rest[:tag_end], "begin")
		content := rest[tag_end + 1:]
		content_end := strings.index_byte(content, '<')
		rest = content

		// A span holding other spans, such as background vocals, is read through its children.
		if content_end < 0 || !strings.has_prefix(content[content_end:], "</span>") do continue

		word_text := to_plain_text(content[:content_end])
		rest = content[content_end + len("</span>"):]
		has_space := len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\n')
		if has_space do word_text = fmt.tprintf("%s ", word_text)

		length := utf16_length(word_text)
		append(&word_list, Word{to_seconds(begin), {utf16_index, utf16_index + length}})
		strings.write_string(&builder, word_text)
		utf16_index += length
	}

	if len(word_list) == 0 {
		plain := to_plain_text(strip_tags(markup))
		append(&word_list, Word{line_begin_seconds, {0, utf16_length(plain)}})
		strings.write_string(&builder, plain)
	}

	return strings.trim_right_space(strings.to_string(builder)), word_list[:]
}

@(private)
strip_tags :: proc(markup: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	is_in_tag := false

	for character in markup {
		switch {
		case character == '<':
			is_in_tag = true
		case character == '>':
			is_in_tag = false
		case !is_in_tag:
			strings.write_rune(&builder, character)
		}
	}

	return strings.to_string(builder)
}

// Letters only, so "You are KING" and its pronunciation "You are KING" count as the same.
@(private)
to_letters :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	for character in strings.to_lower(text, context.temp_allocator) {
		is_space_or_mark := character == ' ' || character == ',' || character == '.' || character == '!' || character == '?' || character == '\'' || character == '"' || character == '-'
		if !is_space_or_mark do strings.write_rune(&builder, character)
	}

	return strings.to_string(builder)
}

// The text of each line in a block of the lyrics' metadata, by the line's key, as "L1": the pronunciation
// in Latin letters for "transliteration", the English for "translation".
@(private)
to_line_texts :: proc(ttml: string, block_name: string) -> map[string]string {
	pronunciations := make(map[string]string, context.temp_allocator)
	start := strings.index(ttml, fmt.tprintf("<%s ", block_name))
	if start < 0 do return pronunciations

	block := ttml[start:]
	if end := strings.index(block, fmt.tprintf("</%s>", block_name)); end >= 0 do block = block[:end]

	for {
		text_start := strings.index(block, "<text for=\"")
		if text_start < 0 do break

		block = block[text_start:]
		tag_end := strings.index_byte(block, '>')
		text_end := strings.index(block, "</text>")
		if tag_end < 0 || text_end < 0 do break

		pronunciations[find_attribute(block[:tag_end], "for")] = block[tag_end + 1:text_end]
		block = block[text_end + len("</text>"):]
	}

	return pronunciations
}

@(private)
to_lines :: proc(ttml: string, allocator: mem.Allocator) -> []Line {
	pronunciations := to_line_texts(ttml, "transliteration")
	translations := to_line_texts(ttml, "translation")
	lines := make([dynamic]Line, allocator)
	body := ttml[max(0, strings.index(ttml, "<body")):]

	for {
		start := strings.index(body, "<p ")
		if start < 0 do break

		body = body[start:]
		tag_end := strings.index_byte(body, '>')
		end := strings.index(body, "</p>")
		if tag_end < 0 || end < 0 do break

		attributes := body[3:tag_end]
		begin_seconds := to_seconds(find_attribute(attributes, "begin"))
		text, words := to_words(body[tag_end + 1:end], begin_seconds, allocator)
		line := Line{begin_seconds = begin_seconds, text = text, words = words}

		key := find_attribute(attributes, "itunes:key")
		if markup, ok := translations[key]; ok {
			line.translation, _ = to_words(markup, begin_seconds, allocator)
		}

		if markup, ok := pronunciations[key]; ok {
			pronunciation, pronunciation_words := to_words(markup, begin_seconds, allocator)

			if to_letters(pronunciation) != to_letters(text) {
				line.pronunciation = pronunciation
				line.pronunciation_words = pronunciation_words
			}
		}

		append(&lines, line)
		body = body[end + len("</p>"):]
	}

	return lines[:]
}

// The catalog ID of a song in the saved queue, found by its name and artist.
@(private)
find_queue_song_id :: proc(name, artist: string, allocator := context.allocator) -> (string, bool) {
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
	if json.unmarshal_string(text, &queue, allocator = context.temp_allocator) != nil do return "", false

	for song in queue.songs {
		if song.name == name && song.artist_name == artist do return strings.clone(song.id, allocator), true
	}

	return "", false
}
