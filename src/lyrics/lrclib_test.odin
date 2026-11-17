package lyrics

import "core:testing"

@(test)
lrc_lines_test :: proc(t: ^testing.T) {
	lrc := "[ar:Ado]\n[00:01.19] 正しさとは\n[00:03.33][00:33.33]repeat\n[00:08.29] \n"
	lines := to_lrc_lines(lrc, context.temp_allocator)

	testing.expect(
		t,
		len(lines) == 4,
		"the metadata line is skipped and the repeated line counts twice",
	)
	testing.expect(t, lines[0].begin_seconds == 1.19, "")
	testing.expect(t, lines[0].text == "正しさとは", "")
	testing.expect(
		t,
		lines[1].begin_seconds == 3.33 && lines[2].begin_seconds == 33.33,
		"a repeat",
	)
	testing.expect(t, lines[1].text == "repeat" && lines[2].text == "repeat", "")
	testing.expect(t, lines[3].text == "", "an empty spacer line stays")

	for line in lines {
		testing.expect(t, len(line.words) == 1, "a line-level lyric gets one whole-line word")
		testing.expect(t, line.words[0].begin_seconds == line.begin_seconds, "")
	}

	testing.expect(t, lines[0].words[0].utf16_range == {0, 5}, "the word spans the whole line")
	testing.expect(t, lines[1].words[0].utf16_range == {0, 6}, "")
}

@(test)
lyricsfile_words_test :: proc(t: ^testing.T) {
	file :=
		"version: '1.0'\nmetadata:\n  title: Blinding Lights\nlines:\n" +
		"- text: Yeah\n  start_ms: 13120\n  end_ms: 14551\n  words:\n  - text: Yeah\n    start_ms: 13159\n" +
		"- text: I've been tryna call\n  start_ms: 27170\n  end_ms: 28268\n  words:\n" +
		"  - text: 'I''ve '\n    start_ms: 27209\n  - text: been\n    start_ms: 27598\n" +
		"- text: No word timings\n  start_ms: 30000\n"
	lines := to_lyricsfile_lines(file, context.temp_allocator)

	testing.expect(t, len(lines) == 3, "")
	testing.expect(t, lines[0].text == "Yeah" && lines[0].begin_seconds == 13.12, "")
	testing.expect(t, lines[0].words[0].begin_seconds == 13.159, "")
	testing.expect(t, lines[0].words[0].utf16_range == {0, 4}, "")

	testing.expect(t, lines[1].text == "I've been", "a line's text is its words joined")
	testing.expect(t, lines[1].begin_seconds == 27.17, "")
	testing.expect(
		t,
		lines[1].words[0].utf16_range == {0, 5},
		"the escaped quote keeps its length",
	)
	testing.expect(t, lines[1].words[0].begin_seconds == 27.209, "")
	testing.expect(t, lines[1].words[1].utf16_range == {5, 9}, "")
	testing.expect(t, lines[1].words[1].begin_seconds == 27.598, "")

	testing.expect(t, lines[2].text == "No word timings", "")
	testing.expect(
		t,
		len(lines[2].words) == 1 && lines[2].words[0].utf16_range == {0, 15},
		"a line without word timings lights up as one word",
	)
}

@(test)
lrclib_fallback_test :: proc(t: ^testing.T) {
	record := LRCLIB_Record {
		has_word_sync = true,
		synced_lyrics = "[00:01.00]fallback\n",
	}

	broken := to_lrclib_lines(record, context.temp_allocator)
	testing.expect(
		t,
		len(broken) == 1 && broken[0].text == "fallback",
		"a broken lyricsfile falls back to the LRC",
	)

	record.instrumental = true
	testing.expect(
		t,
		to_lrclib_lines(record, context.temp_allocator) == nil,
		"an instrumental has no lyrics",
	)
}
