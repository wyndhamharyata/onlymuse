package player

import "core:fmt"
import "core:strconv"
import "om:app/core"
import "om:app/kit"
import "om:helper"
import "om:lyrics"
import "om:platform"
import "om:store"
import "om:ui"

LINES_BEFORE_CURRENT :: 3

LYRIC_FONT_SIZE :: 18

PRONUNCIATION_FONT_SIZE :: 14

LYRIC_LINE_GAP :: 14

OTHER_LINE_OPACITY :: 0.7

// A sung word fades into the accent over this long.
WORD_FADE_SECONDS :: 0.15

// The lines glide to their new place at this rate per second.
SLIDE_RATE :: 9

LINE_FADE_RATE :: 10

// How far ahead of Music.app's position the lyrics run. Music.app's posts run about half a second behind what it plays.
DEFAULT_LEAD_MS :: 500

LEAD_STEP_MS :: 50

MAX_LEAD_MS :: 2000

LEAD_NOTE_SECONDS :: 2

// The timer for the next word fires this much after its start, so a word is never a hair early.
WORD_TIMER_SLACK_SECONDS :: 0.005

lyrics_state: struct {
	lead_ms:           int,
	lead_changed_tick: f64,
	// The lyrics' time, in song seconds, for the frame being built.
	position_seconds:  f64,
	current_index:     int,
	lines:             []lyrics.Line,
	// What shows under each line, when the song has it. Saved.
	shows_romaji:      bool,
	shows_translation: bool,
}

TRANSLATION_FONT_SIZE :: 13

// The saved lead and the lyrics' switches.
start_lyrics :: proc() {
	lyrics_state.lead_ms = DEFAULT_LEAD_MS
	lyrics_state.shows_romaji =
		(store.find_state("lyricsRomaji", context.temp_allocator) or_else "true") == "true"
	lyrics_state.shows_translation =
		(store.find_state("lyricsTranslation", context.temp_allocator) or_else "false") == "true"

	if text, ok := store.find_state("lyricLeadMs", context.temp_allocator); ok {
		lead_ms, is_number := strconv.parse_int(text)
		if is_number && abs(lead_ms) <= MAX_LEAD_MS do lyrics_state.lead_ms = lead_ms
	}
}

// Cmd ] runs the lyrics 50 ms earlier, Cmd [ 50 ms later.
apply_lead_key :: proc(key: platform.Key_Press) {
	step := 0

	switch key.characters {
	case "]":
		step = LEAD_STEP_MS
	case "[":
		step = -LEAD_STEP_MS
	}

	next := lyrics_state.lead_ms + step
	if step == 0 || abs(next) > MAX_LEAD_MS do return

	lyrics_state.lead_ms = next
	lyrics_state.lead_changed_tick = helper.now_ms()
	store.save_state("lyricLeadMs", fmt.tprintf("%d", next))
}

// The line being sung is the last one that has begun.
find_current_line :: proc(lines: []lyrics.Line, position_seconds: f64) -> int {
	current := -1

	for line, index in lines {
		if line.begin_seconds <= position_seconds do current = index
	}

	return current
}

// The next moment the lyrics change after now, or -1 when none is left.
find_next_change :: proc(lines: []lyrics.Line, position_seconds: f64) -> f64 {
	next := -1.0

	for line in lines {
		for word in line.words {
			is_later := word.begin_seconds > position_seconds
			if is_later && (next < 0 || word.begin_seconds < next) do next = word.begin_seconds
		}

		for word in line.pronunciation_words {
			is_later := word.begin_seconds > position_seconds
			if is_later && (next < 0 || word.begin_seconds < next) do next = word.begin_seconds
		}
	}

	return next
}

// True while a word or line still fades. Else it sets a timer for the next word, so no frame is drawn between words.
schedule_lyrics :: proc(lines: []lyrics.Line) -> bool {
	if core.app.now_playing.playback != .Playing do return false

	position := lyrics_state.position_seconds
	latest_begin := -1.0

	for line in lines {
		for word in line.words {
			if word.begin_seconds <= position {
				latest_begin = max(latest_begin, word.begin_seconds)
			}
		}
	}

	if latest_begin >= 0 && position - latest_begin < WORD_FADE_SECONDS do return true

	next := find_next_change(lines, position)
	if next >= 0 do platform.request_frame_after(next - position + WORD_TIMER_SLACK_SECONDS)

	return false
}

build_lyrics :: proc() -> bool {
	now_playing := core.app.now_playing
	song := now_playing.song
	is_song := now_playing.playback == .Playing || now_playing.playback == .Paused

	if !is_song {
		build_panel_note("Nothing is playing.")
		return false
	}

	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			text_color = kit.colors.text,
			font_weight = .Semibold,
			padding = {8, 0, 8, 0},
			flags = {.Truncate_Text},
		},
		song.name,
	)
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			text_color = kit.colors.dim,
			font_size = 12,
			padding = {8, 0, 8, 10},
			flags = {.Truncate_Text},
		},
		song.artist,
	)

	phase, lines := lyrics.find(song.persistent_id, song.name, song.artist)

	switch phase {
	case .None, .Loading:
		build_panel_note("Loading the lyrics.")
		return false
	case .Missing:
		build_panel_note("Apple Music has no lyrics for this song.")
		return false
	case .Ready:
	}

	build_lyric_toggles(lines)

	lead_seconds := f64(lyrics_state.lead_ms) / 1000
	lyrics_state.position_seconds = helper.position_seconds(now_playing) + lead_seconds
	lyrics_state.current_index = find_current_line(lines, lyrics_state.position_seconds)
	lyrics_state.lines = lines

	view := ui.box(
		"lyrics",
		{width = ui.fill(), height = ui.fill(), padding = {8, 10, 8, 0}, flags = {.Clip}},
	)

	// The top of the line three before the current one, from last frame's layout.
	first_shown := max(0, lyrics_state.current_index - LINES_BEFORE_CURRENT)
	target_offset: f32
	column := ui.find_box("column", view)

	if column != nil {
		if first_line := ui.find_box(fmt.tprintf("line %d", first_shown), column);
		   first_line != nil {
			target_offset = first_line.rect.y - column.rect.y
		}
	}

	offset := ui.animate("lyrics offset", target_offset, SLIDE_RATE)

	if ui.scope(view) {
		column = ui.box(
			"column",
			{
				width = ui.fill(),
				height = ui.fit_children(),
				axis = .Y,
				gap = LYRIC_LINE_GAP,
				position = {8, 10 - offset},
				flags = {.Floating},
			},
		)

		if ui.scope(column) {
			for &line, index in lines do build_lyric_line(&line, index)
		}

		build_lead_note()
	}

	return schedule_lyrics(lines)
}

build_panel_note :: proc(text: string) {
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			text_color = kit.colors.dim,
			padding = {8, 16, 8, 0},
			flags = {.Wrap_Text},
		},
		text,
	)
}

// Romaji and Translation, each shown only when a line of the song has it.
@(private = "file")
build_lyric_toggles :: proc(lines: []lyrics.Line) {
	has_romaji, has_translation := false, false

	for line in lines {
		has_romaji ||= line.pronunciation != ""
		has_translation ||= line.translation != ""
	}

	if !has_romaji && !has_translation do return

	toggles := ui.box(
		"toggles",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .X,
			gap = 6,
			padding = {8, 0, 8, 10},
		},
	)

	if ui.scope(toggles) {
		if has_romaji && kit.toggle_chip("Romaji", lyrics_state.shows_romaji) {
			lyrics_state.shows_romaji = !lyrics_state.shows_romaji
			store.save_state("lyricsRomaji", "true" if lyrics_state.shows_romaji else "false")
		}

		if has_translation && kit.toggle_chip("Translation", lyrics_state.shows_translation) {
			lyrics_state.shows_translation = !lyrics_state.shows_translation
			store.save_state(
				"lyricsTranslation",
				"true" if lyrics_state.shows_translation else "false",
			)
		}
	}
}
