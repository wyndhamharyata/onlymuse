package matching

import "core:fmt"
import "core:strings"
import "core:unicode"
import "om:app/core"

// Two lengths this close are one recording. A remaster or a TV-size edit differs by more.
MATCH_SECONDS :: 3

// The closest in length of the candidates that are the same recording.
@(private)
find_closest :: proc(
	song: core.Catalog_Song,
	candidates: []core.Catalog_Song,
) -> (
	core.Catalog_Song,
	bool,
) {
	best: core.Catalog_Song
	is_found := false

	for candidate in candidates {
		if !is_same_recording(song, candidate) do continue

		is_closer :=
			!is_found ||
			abs(candidate.duration_seconds - song.duration_seconds) <
				abs(best.duration_seconds - song.duration_seconds)
		if is_closer do best = candidate
		is_found = true
	}

	return best, is_found
}

// One recording has the same cleaned title, the same artist and about the same length.
is_same_recording :: proc(youtube_song, apple_song: core.Catalog_Song) -> bool {
	has_lengths := youtube_song.duration_seconds > 0 && apple_song.duration_seconds > 0
	length_difference := abs(youtube_song.duration_seconds - apple_song.duration_seconds)

	if !has_same_title(youtube_song.name, apple_song.name) do return false
	if has_lengths && length_difference > MATCH_SECONDS do return false

	return is_same_artist(youtube_song.artist_name, apple_song.artist_name)
}

// "Ado" and "ADO" are one artist. "SHE'S" and "SHE'S, Yuta Kanazawa" are one artist too.
// An artist under two names, such as a Japanese name on one side, is no match. YouTube plays it.
@(private)
is_same_artist :: proc(youtube_artist, apple_artist: string) -> bool {
	youtube_key := to_match_key(youtube_artist)
	apple_key := to_match_key(apple_artist)

	return(
		youtube_key != "" &&
		apple_key != "" &&
		(strings.contains(apple_key, youtube_key) || strings.contains(youtube_key, apple_key)) \
	)
}

@(private)
has_same_title :: proc(youtube_name, apple_name: string) -> bool {
	apple_titles := list_title_keys(apple_name)

	for title in list_title_keys(youtube_name) {
		for apple_title in apple_titles do if title == apple_title do return true
	}

	return false
}

// The whole title and each half around " - " or " / ", as match keys. YouTube often writes
// a Japanese title and its romaji as "追い風 - Oikaze". Apple writes one, so either half matches.
@(private)
list_title_keys :: proc(name: string) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	append(&keys, to_match_key(name))

	for separator in ([]string{" - ", " / ", "／"}) {
		if !strings.contains(name, separator) do continue

		for part in strings.split(name, separator, context.temp_allocator) {
			if key := to_match_key(part); key != "" {
				append(&keys, key)
			}
		}
	}

	return keys[:]
}

// Lowercase letters and digits only, without "feat." and what follows it. It drops the parts in
// brackets, such as "(Official Video)" or "【MV】". A name that is all brackets keeps them.
to_match_key :: proc(text: string) -> string {
	lower := strings.to_lower(text, context.temp_allocator)

	for marker in ([]string{" feat.", " feat ", " ft.", " (feat", " [feat"}) {
		if index := strings.index(lower, marker); index > 0 do lower = lower[:index]
	}

	key := to_letters(lower, true)

	return key if key != "" else to_letters(lower, false)
}

@(private = "file")
to_letters :: proc(text: string, skips_brackets: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		switch character {
		case '(', '[', '【', '『', '「', '（', '［':
			depth += 1
			continue
		case ')', ']', '】', '』', '」', '）', '］':
			depth = max(0, depth - 1)
			continue
		}

		is_kept := unicode.is_letter(character) || unicode.is_digit(character)
		if is_kept && (depth == 0 || !skips_brackets) do strings.write_rune(&builder, character)
	}

	return strings.to_string(builder)
}

// The title, the album and the artist, without the parts in brackets or the apostrophes.
// Apple's search finds nothing for a term with an apostrophe, such as "She's".
@(private)
to_search_term :: proc(song: core.Catalog_Song, album: string) -> string {
	return fmt.tprintf(
		"%s %s %s",
		to_plain_text(song.name),
		to_plain_text(album),
		to_plain_text(song.artist_name),
	)
}

// The text without its bracketed parts and apostrophes. Text that is all brackets keeps them.
@(private)
to_plain_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		switch character {
		case '(', '[', '【', '『', '「', '（', '［':
			depth += 1
		case ')', ']', '】', '』', '」', '）', '］':
			depth = max(0, depth - 1)
		case '\'', '’':
		case:
			if depth == 0 do strings.write_rune(&builder, character)
		}
	}

	plain := strings.trim_space(strings.to_string(builder))

	return plain if plain != "" else text
}
