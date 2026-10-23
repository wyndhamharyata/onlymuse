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

TRANSLATION_FONT_SIZE :: 13

LYRIC_LINE_GAP :: 14

PANEL_INSET_POINTS :: 8

OTHER_LINE_OPACITY :: 0.7

WORD_FADE_SECONDS :: 0.15

SLIDE_RATE_PER_SECOND :: 9

LINE_FADE_RATE_PER_SECOND :: 10

// Music.app's posts run about half a second behind what it plays.
DEFAULT_LEAD_MS :: 500

LEAD_STEP_MS :: 50

MAX_LEAD_MS :: 2000

LEAD_NOTE_SECONDS :: 2

// A frame timer fires this long after the moment it waits for, so no frame shows a change early.
TIMER_SLACK_SECONDS :: 0.005

lyrics_state: struct {
	lead_ms:                int,
	lead_changed_ms:        f64,
	position_seconds:       f64,
	current_index:          int,
	lines:                  []lyrics.Line,
	is_showing_romaji:      bool,
	is_showing_translation: bool,
}

start_lyrics :: proc() {
	lyrics_state.lead_ms = DEFAULT_LEAD_MS
	lyrics_state.is_showing_romaji =
		(store.find_state("lyricsRomaji", context.temp_allocator) or_else "true") == "true"
	lyrics_state.is_showing_translation =
		(store.find_state("lyricsTranslation", context.temp_allocator) or_else "false") == "true"

	text, has_lead := store.find_state("lyricLeadMs", context.temp_allocator)
	if !has_lead do return

	lead_ms, is_number := strconv.parse_int(text)
	if is_number && abs(lead_ms) <= MAX_LEAD_MS do lyrics_state.lead_ms = lead_ms
}

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
	lyrics_state.lead_changed_ms = helper.now_ms()
	store.save_state("lyricLeadMs", fmt.tprintf("%d", next))
}

find_current_line :: proc(lines: []lyrics.Line, position_seconds: f64) -> int {
	current := -1

	for line, index in lines {
		if line.begin_seconds <= position_seconds do current = index
	}

	return current
}

find_next_change :: proc(lines: []lyrics.Line, position_seconds: f64) -> f64 {
	next := -1.0

	for line in lines {
		for words in ([][]lyrics.Word{line.words, line.pronunciation_words}) {
			for word in words {
				is_later := word.begin_seconds > position_seconds
				if is_later && (next < 0 || word.begin_seconds < next) do next = word.begin_seconds
			}
		}
	}

	return next
}

start_lyrics_timer :: proc(lines: []lyrics.Line, position_seconds: f64) {
	next := find_next_change(lines, position_seconds)
	if next >= 0 do platform.request_frame_after(next - position_seconds + TIMER_SLACK_SECONDS)
}

is_word_fading :: proc(lines: []lyrics.Line, position_seconds: f64) -> bool {
	latest_begin := -1.0

	for line in lines {
		for word in line.words {
			if word.begin_seconds <= position_seconds {
				latest_begin = max(latest_begin, word.begin_seconds)
			}
		}
	}

	return latest_begin >= 0 && position_seconds - latest_begin < WORD_FADE_SECONDS
}

to_lyrics_position_seconds :: proc(now_playing: helper.Now_Playing, lead_ms: int) -> f64 {
	return helper.read_position_seconds(now_playing) + f64(lead_ms) / 1000
}

build_lyrics :: proc() -> bool {
	now_playing := core.app.now_playing
	song := now_playing.song
	has_song := helper.has_song(now_playing)

	if !has_song {
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
			padding = {PANEL_INSET_POINTS, 0, PANEL_INSET_POINTS, 0},
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
			padding = {PANEL_INSET_POINTS, 0, PANEL_INSET_POINTS, 10},
			flags = {.Truncate_Text},
		},
		song.artist_name,
	)

	phase, lines := lyrics.watch(song.persistent_id, song.name, song.artist_name)

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

	position_seconds := to_lyrics_position_seconds(now_playing, lyrics_state.lead_ms)
	lyrics_state.position_seconds = position_seconds
	lyrics_state.current_index = find_current_line(lines, position_seconds)
	lyrics_state.lines = lines

	view := ui.box(
		"lyrics",
		{
			width = ui.fill(),
			height = ui.fill(),
			padding = {PANEL_INSET_POINTS, 10, PANEL_INSET_POINTS, 0},
			flags = {.Clip},
		},
	)

	first_shown := max(0, lyrics_state.current_index - LINES_BEFORE_CURRENT)
	target_offset: f32
	column := ui.find_box("column", view)
	first_line :=
		ui.find_box(fmt.tprintf("line %d", first_shown), column) if column != nil else nil

	if first_line != nil do target_offset = first_line.rect.y - column.rect.y

	offset := ui.animate("lyrics offset", target_offset, SLIDE_RATE_PER_SECOND)

	if ui.scope(view) {
		column = ui.box(
			"column",
			{
				width = ui.fill(),
				height = ui.fit_children(),
				axis = .Y,
				gap = LYRIC_LINE_GAP,
				position = {PANEL_INSET_POINTS, 10 - offset},
				flags = {.Floating},
			},
		)

		if ui.scope(column) {
			for &line, index in lines do build_lyric_line(&line, index)
		}

		build_lead_note()
	}

	if now_playing.playback != .Playing do return false
	if is_word_fading(lines, position_seconds) do return true

	start_lyrics_timer(lines, position_seconds)

	return false
}

build_panel_note :: proc(text: string) {
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			text_color = kit.colors.dim,
			padding = {PANEL_INSET_POINTS, 16, PANEL_INSET_POINTS, 0},
			flags = {.Wrap_Text},
		},
		text,
	)
}

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
			padding = {PANEL_INSET_POINTS, 0, PANEL_INSET_POINTS, 10},
		},
	)

	if ui.scope(toggles) {
		if has_romaji && kit.toggle_chip("Romaji", lyrics_state.is_showing_romaji) {
			lyrics_state.is_showing_romaji = !lyrics_state.is_showing_romaji
			store.save_state("lyricsRomaji", "true" if lyrics_state.is_showing_romaji else "false")
		}

		if has_translation && kit.toggle_chip("Translation", lyrics_state.is_showing_translation) {
			lyrics_state.is_showing_translation = !lyrics_state.is_showing_translation
			store.save_state(
				"lyricsTranslation",
				"true" if lyrics_state.is_showing_translation else "false",
			)
		}
	}
}
