package lyrics

// LRCLIB (lrclib.net) is a free, open lyrics database with a public API and no account. It holds the
// lyrics of songs that play from YouTube, which are on no Apple Music catalog.
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "om:apple"
import "om:net"

LRCLIB_Record :: struct {
	duration:      f64,
	instrumental:  bool,
	has_word_sync: bool `json:"hasWordSync"`,
	synced_lyrics: string `json:"syncedLyrics"`,
	lyricsfile:    string,
}

fetch_lrclib_lines :: proc(
	name, artist: string,
	duration_seconds: f64,
	allocator: mem.Allocator,
) -> []Line {
	headers := []string{"User-Agent: onlymuse/1.0"}

	answer := net.fetch(
		fmt.tprintf(
			"https://lrclib.net/api/get?artist_name=%s&track_name=%s&duration=%d",
			apple.to_query_text(artist),
			apple.to_query_text(name),
			int(duration_seconds + 0.5),
		),
		headers,
	)

	if answer.status == 200 {
		record: LRCLIB_Record
		if json.unmarshal_string(
			   string(answer.body),
			   &record,
			   allocator = context.temp_allocator,
		   ) !=
		   nil {
			return nil
		}
		return to_lrclib_lines(record, allocator)
	}

	// A wrong duration can make the exact match miss, so a search picks the closest recording.
	search := net.fetch(
		fmt.tprintf(
			"https://lrclib.net/api/search?artist_name=%s&track_name=%s",
			apple.to_query_text(artist),
			apple.to_query_text(name),
		),
		headers,
	)
	if search.status != 200 do return nil

	records: []LRCLIB_Record
	if json.unmarshal_string(string(search.body), &records, allocator = context.temp_allocator) !=
	   nil {
		return nil
	}

	best: ^LRCLIB_Record = nil
	best_gap := 0.0

	for &record in records {
		if record.instrumental do continue
		if !record.has_word_sync && record.synced_lyrics == "" do continue

		gap := abs(record.duration - duration_seconds)
		if best == nil || gap < best_gap {
			best = &record
			best_gap = gap
		}
	}

	if best == nil || best_gap > 5 do return nil

	return to_lrclib_lines(best^, allocator)
}

@(private)
to_lrclib_lines :: proc(record: LRCLIB_Record, allocator: mem.Allocator) -> []Line {
	if record.instrumental do return nil

	if record.has_word_sync {
		if lines := to_lyricsfile_lines(record.lyricsfile, allocator); len(lines) > 0 do return lines
	}

	return to_lrc_lines(record.synced_lyrics, allocator)
}

// An LRC line is "[mm:ss.xx] text". A line can carry several times, one per repeat.
@(private)
to_lrc_lines :: proc(lrc: string, allocator: mem.Allocator) -> []Line {
	lines := make([dynamic]Line, allocator)

	for raw in strings.split(lrc, "\n", context.temp_allocator) {
		text := strings.trim_space(raw)
		if !strings.has_prefix(text, "[") do continue

		begins := [8]f64{}
		count := 0

		for strings.has_prefix(text, "[") {
			end := strings.index_byte(text, ']')
			if end < 0 do break

			seconds, is_time := to_lrc_seconds(text[1:end])
			if is_time && count < len(begins) {
				begins[count] = seconds
				count += 1
			}

			text = text[end + 1:]
		}

		text = strings.trim_space(text)
		if count == 0 do continue

		for index in 0 ..< count {
			append(
				&lines,
				Line {
					begin_seconds = begins[index],
					text = strings.clone(text, allocator),
					words = to_whole_line_words(begins[index], text, allocator),
				},
			)
		}
	}

	return lines[:]
}

@(private)
to_lrc_seconds :: proc(tag: string) -> (f64, bool) {
	colon := strings.index_byte(tag, ':')
	if colon < 0 do return 0, false

	minutes, is_minutes := strconv.parse_int(tag[:colon])
	seconds, is_seconds := strconv.parse_f64(tag[colon + 1:])
	if !is_minutes || !is_seconds do return 0, false

	return f64(minutes) * 60 + seconds, true
}

// Without a word the line never paints as current, so a line-level lyric gets one word that spans it.
@(private)
to_whole_line_words :: proc(begin_seconds: f64, text: string, allocator: mem.Allocator) -> []Word {
	words := make([]Word, 1, allocator)
	words[0] = {
		begin_seconds = begin_seconds,
		utf16_range   = {0, to_utf16_length(text)},
	}

	return words
}

// lyricsfile holds LRCLIB's YAML, with each line's text and start_ms, and each word's text and
// start_ms when the record has word sync. A line's text is its words joined, so the word ranges
// stay true.
@(private)
to_lyricsfile_lines :: proc(file: string, allocator: mem.Allocator) -> []Line {
	lines := make([dynamic]Line, allocator)
	words := make([dynamic]Word, allocator)
	text_bytes := make([dynamic]u8, context.temp_allocator)
	utf16_index := 0
	is_in_lines := false

	for raw in strings.split(file, "\n", context.temp_allocator) {
		if !is_in_lines {
			if strings.has_prefix(raw, "lines:") do is_in_lines = true
			continue
		}

		entry := strings.trim_space(raw)
		if entry == "" do continue

		indent := len(raw) - len(strings.trim_left(raw, " "))

		if indent == 0 {
			if !strings.has_prefix(entry, "- text:") do break

			if len(lines) > 0 do set_line_words(&lines[len(lines) - 1], &words, &text_bytes, allocator)
			append(
				&lines,
				Line{text = strings.clone(to_scalar(entry[len("- text:"):]), allocator)},
			)
			utf16_index = 0
			continue
		}

		if len(lines) == 0 do continue

		if indent == 2 && strings.has_prefix(entry, "- text:") {
			text := to_scalar(entry[len("- text:"):])
			append(&text_bytes, ..transmute([]u8)text)
			length := to_utf16_length(text)
			append(&words, Word{utf16_range = {utf16_index, utf16_index + length}})
			utf16_index += length
		} else if strings.has_prefix(entry, "start_ms:") {
			milliseconds, is_number := strconv.parse_int(
				strings.trim_space(entry[len("start_ms:"):]),
			)
			if !is_number do continue

			// A line's start_ms comes before its words, so words present means the time is a word's.
			if len(words) > 0 && indent >= 4 {
				words[len(words) - 1].begin_seconds = f64(milliseconds) / 1000
			} else {
				lines[len(lines) - 1].begin_seconds = f64(milliseconds) / 1000
			}
		}
	}

	if len(lines) > 0 do set_line_words(&lines[len(lines) - 1], &words, &text_bytes, allocator)

	return lines[:]
}

@(private)
set_line_words :: proc(
	line: ^Line,
	words: ^[dynamic]Word,
	text_bytes: ^[dynamic]u8,
	allocator: mem.Allocator,
) {
	if len(words^) > 0 {
		line.text = strings.clone(string(text_bytes[:]), allocator)
		line.words = make([]Word, len(words^), allocator)
		for word, index in words^ do line.words[index] = word
	} else if line.text != "" {
		line.words = to_whole_line_words(line.begin_seconds, line.text, allocator)
	}

	clear(words)
	clear(text_bytes)
}

// A YAML scalar is plain, single-quoted with '' as an escaped quote, or double-quoted.
@(private)
to_scalar :: proc(value: string) -> string {
	text := strings.trim_space(value)

	if len(text) >= 2 && strings.has_prefix(text, "'") && strings.has_suffix(text, "'") {
		unquoted, _ := strings.replace_all(
			text[1:len(text) - 1],
			"''",
			"'",
			context.temp_allocator,
		)
		return unquoted
	}
	if len(text) >= 2 && strings.has_prefix(text, "\"") && strings.has_suffix(text, "\"") {
		return text[1:len(text) - 1]
	}

	return text
}
