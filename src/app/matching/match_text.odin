package matching

import "core:fmt"
import "core:strings"
import "core:unicode"
import "om:app/core"

// Two lengths this close are one recording. A remaster or a TV-size edit differs by more.
MAX_LENGTH_DIFFERENCE_SECONDS :: 3

@(private = "file")
TITLE_SEPARATORS := [?]string{" - ", " / ", "／"}

@(private = "file")
FEATURE_MARKERS := [?]string{" feat.", " feat ", " ft.", " (feat", " [feat"}

@(private = "file")
OPEN_BRACKETS :: "([【『「（［"

@(private = "file")
CLOSE_BRACKETS :: ")]】』」）］"

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

is_same_recording :: proc(youtube_song, apple_song: core.Catalog_Song) -> bool {
	has_lengths := youtube_song.duration_seconds > 0 && apple_song.duration_seconds > 0
	length_difference_seconds := abs(youtube_song.duration_seconds - apple_song.duration_seconds)

	if !has_same_title(youtube_song.name, apple_song.name) do return false
	if has_lengths && length_difference_seconds > MAX_LENGTH_DIFFERENCE_SECONDS do return false

	return is_same_artist(youtube_song.artist_name, apple_song.artist_name)
}

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

// YouTube joins a Japanese title and its romaji as "追い風 - Oikaze". Apple writes one.
@(private)
list_title_keys :: proc(name: string) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	append(&keys, to_match_key(name))

	for separator in TITLE_SEPARATORS {
		if !strings.contains(name, separator) do continue

		for part in strings.split(name, separator, context.temp_allocator) {
			if key := to_match_key(part); key != "" {
				append(&keys, key)
			}
		}
	}

	return keys[:]
}

to_match_key :: proc(text: string) -> string {
	lower := strings.to_lower(text, context.temp_allocator)

	for marker in FEATURE_MARKERS {
		if index := strings.index(lower, marker); index > 0 do lower = lower[:index]
	}

	key := to_letters(lower, is_bracket_skipped = true)

	return key if key != "" else to_letters(lower, is_bracket_skipped = false)
}

@(private = "file")
to_bracket_depth :: proc(depth: int, character: rune) -> (int, bool) {
	if strings.contains_rune(OPEN_BRACKETS, character) do return depth + 1, true
	if strings.contains_rune(CLOSE_BRACKETS, character) do return max(0, depth - 1), true

	return depth, false
}

@(private = "file")
to_letters :: proc(text: string, is_bracket_skipped: bool) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		is_bracket: bool
		depth, is_bracket = to_bracket_depth(depth, character)
		is_letter := unicode.is_letter(character) || unicode.is_digit(character)
		is_kept := !is_bracket && is_letter && (depth == 0 || !is_bracket_skipped)

		if is_kept do strings.write_rune(&builder, character)
	}

	return strings.to_string(builder)
}

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

@(private)
to_plain_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	depth := 0

	for character in text {
		is_bracket: bool
		depth, is_bracket = to_bracket_depth(depth, character)
		is_apostrophe := character == '\'' || character == '’'

		if !is_bracket && !is_apostrophe && depth == 0 do strings.write_rune(&builder, character)
	}

	plain := strings.trim_space(strings.to_string(builder))

	return plain if plain != "" else text
}
