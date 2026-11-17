package lyrics

// YouTube serves a video's written captions as timedtext XML, with a line per p element and, when
// the track has word timings, a word per s element.
import "core:mem"
import "core:strconv"
import "core:strings"

to_caption_lines :: proc(xml: string, allocator: mem.Allocator) -> []Line {
	lines := make([dynamic]Line, allocator)

	rest := xml
	for {
		start := strings.index(rest, "<p ")
		if start < 0 do break

		end := strings.index(rest[start:], "</p>")
		if end < 0 do break

		element := rest[start:start + end + len("</p>")]
		rest = rest[start + end + len("</p>"):]

		append_caption_line(&lines, element, allocator)
	}

	return lines[:]
}

@(private)
append_caption_line :: proc(lines: ^[dynamic]Line, element: string, allocator: mem.Allocator) {
	header_end := strings.index(element, ">")
	if header_end < 0 do return

	begin_seconds := to_caption_seconds(find_attribute(element[:header_end], "t"))
	if begin_seconds < 0 do return

	inner := element[header_end + 1:len(element) - len("</p>")]

	if strings.contains(inner, "<s") {
		text, words := to_caption_words(inner, begin_seconds, allocator)
		if text != "" do append(lines, Line{begin_seconds = begin_seconds, text = text, words = words})
		return
	}

	// A cue can hold two lines of screen text.
	for part in strings.split(to_plain_text(inner), "\n", context.temp_allocator) {
		text := strings.trim_space(part)
		if text == "" do continue

		append(
			lines,
			Line {
				begin_seconds = begin_seconds,
				text = strings.clone(text, allocator),
				words = to_whole_line_words(begin_seconds, text, allocator),
			},
		)
	}
}

// An s element's time is relative to its line's time.
@(private)
to_caption_words :: proc(
	inner: string,
	line_begin_seconds: f64,
	allocator: mem.Allocator,
) -> (
	string,
	[]Word,
) {
	words := make([dynamic]Word, allocator)
	text_bytes := make([dynamic]u8, context.temp_allocator)
	utf16_index := 0

	rest := inner
	for {
		start := strings.index(rest, "<s")
		if start < 0 do break

		rest = rest[start:]
		tag_end := strings.index(rest, ">")
		if tag_end < 0 do break

		word_end := strings.index(rest[tag_end:], "</s>")
		if word_end < 0 do break

		offset_seconds := to_caption_seconds(find_attribute(rest[:tag_end], "t"))
		word_text := to_plain_text(rest[tag_end + 1:tag_end + word_end])

		rest = rest[tag_end + word_end + len("</s>"):]

		append(&text_bytes, ..transmute([]u8)word_text)
		length := to_utf16_length(word_text)
		begin_seconds := line_begin_seconds + (offset_seconds if offset_seconds >= 0 else 0)
		append(
			&words,
			Word{begin_seconds = begin_seconds, utf16_range = {utf16_index, utf16_index + length}},
		)
		utf16_index += length
	}

	return string(text_bytes[:]), words[:]
}

@(private)
to_caption_seconds :: proc(milliseconds: string) -> f64 {
	value, is_number := strconv.parse_int(milliseconds)

	return f64(value) / 1000 if is_number else -1
}
