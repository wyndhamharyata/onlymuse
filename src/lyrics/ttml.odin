package lyrics

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

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
	// "&amp;" comes last, so "&amp;lt;" turns into the text "&lt;" and never into "<".
	entities := [][2]string {
		{"&lt;", "<"},
		{"&gt;", ">"},
		{"&apos;", "'"},
		{"&quot;", "\""},
		{"&amp;", "&"},
	}

	for entity in entities {
		text, _ = strings.replace_all(text, entity[0], entity[1], context.temp_allocator)
	}

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

// CoreText counts in UTF-16 units. A character above U+FFFF takes two of them.
@(private)
to_utf16_length :: proc(text: string) -> int {
	count := 0
	for character in text do count += 2 if character >= 0x10000 else 1

	return count
}

// A word is a span with its own begin time. The space after a word stays with the word,
// so the words join back into the line.
@(private)
to_words :: proc(
	markup: string,
	line_begin_seconds: f64,
	allocator: mem.Allocator,
) -> (
	text: string,
	words: []Word,
) {
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

		// For a span that holds spans, such as background vocals, the loop reads the inner spans.
		if content_end < 0 || !strings.has_prefix(content[content_end:], "</span>") do continue

		word_text := to_plain_text(content[:content_end])
		rest = content[content_end + len("</span>"):]
		has_space := len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\n')
		if has_space do word_text = fmt.tprintf("%s ", word_text)

		length := to_utf16_length(word_text)
		append(&word_list, Word{to_seconds(begin), {utf16_index, utf16_index + length}})
		strings.write_string(&builder, word_text)
		utf16_index += length
	}

	// A song timed by line has no spans, so the whole line becomes one word.
	if len(word_list) == 0 {
		plain := to_plain_text(to_text_without_tags(markup))
		append(&word_list, Word{line_begin_seconds, {0, to_utf16_length(plain)}})
		strings.write_string(&builder, plain)
	}

	return strings.trim_right_space(strings.to_string(builder)), word_list[:]
}

@(private)
to_text_without_tags :: proc(markup: string) -> string {
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

// Keeps the letters only, so "You are KING!" and its pronunciation "you are king" match.
@(private)
to_letters :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)

	for character in strings.to_lower(text, context.temp_allocator) {
		is_space_or_mark :=
			character == ' ' ||
			character == ',' ||
			character == '.' ||
			character == '!' ||
			character == '?' ||
			character == '\'' ||
			character == '"' ||
			character == '-'
		if !is_space_or_mark do strings.write_rune(&builder, character)
	}

	return strings.to_string(builder)
}

// The text of each line in one block of the lyrics' metadata, by the line's key, such as "L1".
// "transliteration" holds the pronunciation in Latin letters. "translation" holds the English.
@(private)
to_line_texts :: proc(ttml: string, block_name: string) -> map[string]string {
	line_texts := make(map[string]string, context.temp_allocator)
	start := strings.index(ttml, fmt.tprintf("<%s ", block_name))
	if start < 0 do return line_texts

	block := ttml[start:]

	if end := strings.index(block, fmt.tprintf("</%s>", block_name)); end >= 0 {
		block = block[:end]
	}

	for {
		text_start := strings.index(block, "<text for=\"")
		if text_start < 0 do break

		block = block[text_start:]
		tag_end := strings.index_byte(block, '>')
		text_end := strings.index(block, "</text>")
		if tag_end < 0 || text_end < 0 do break

		line_texts[find_attribute(block[:tag_end], "for")] = block[tag_end + 1:text_end]
		block = block[text_end + len("</text>"):]
	}

	return line_texts
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
		line := Line {
			begin_seconds = begin_seconds,
			text          = text,
			words         = words,
		}

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
