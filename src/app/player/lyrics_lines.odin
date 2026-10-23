package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:helper"
import "om:lyrics"
import "om:platform"
import "om:ui"

to_fade :: proc(begin_seconds, position_seconds: f64) -> f32 {
	return f32(clamp((position_seconds - begin_seconds) / WORD_FADE_SECONDS, 0, 1))
}

Line_Paint :: struct {
	index, current_index:                    int,
	words:                                   []lyrics.Word,
	position_seconds, current_begin_seconds: f64,
}

to_lyric_glyph_color :: proc(utf16_index: int, data: rawptr) -> [4]f32 {
	paint := cast(^Line_Paint)data
	is_current_line := paint.index == paint.current_index
	is_line_before := paint.index == paint.current_index - 1
	lit: f32

	for word in paint.words {
		is_out_of_range := utf16_index < word.utf16_range.x || utf16_index >= word.utf16_range.y
		if is_out_of_range do continue

		is_sung := word.begin_seconds <= paint.position_seconds

		if is_current_line {
			lit = to_fade(word.begin_seconds, paint.position_seconds)
		} else if is_line_before && is_sung {
			lit = 1 - to_fade(paint.current_begin_seconds, paint.position_seconds)
		}

		break
	}

	return kit.colors.dim + (core.app.accent - kit.colors.dim) * lit
}

@(private = "file")
build_timed_text :: proc(text: string, words: []lyrics.Word, index: int, font_size: f32) {
	current := lyrics_state.current_index
	current_begin_seconds := lyrics_state.lines[current].begin_seconds if current >= 0 else 0
	paint := new(Line_Paint, context.temp_allocator)
	paint^ = {index, current, words, lyrics_state.position_seconds, current_begin_seconds}

	box := ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			font_size = font_size,
			font_weight = .Bold,
			text_color = kit.colors.dim,
			flags = {.Wrap_Text},
		},
		text,
	)
	box.color_of = to_lyric_glyph_color
	box.data = paint
}

build_lyric_line :: proc(line: ^lyrics.Line, index: int) {
	is_current := index == lyrics_state.current_index
	opacity := ui.animate(
		fmt.tprintf("lyric opacity %d", index),
		1 if is_current else OTHER_LINE_OPACITY,
		LINE_FADE_RATE_PER_SECOND,
	)
	line_box := ui.box(
		fmt.tprintf("line %d", index),
		{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2, fade = 1 - opacity},
	)

	if ui.scope(line_box) {
		build_timed_text(line.text, line.words, index, LYRIC_FONT_SIZE)

		if line.pronunciation != "" && lyrics_state.is_showing_romaji {
			build_timed_text(
				line.pronunciation,
				line.pronunciation_words,
				index,
				PRONUNCIATION_FONT_SIZE,
			)
		}

		if line.translation != "" && lyrics_state.is_showing_translation {
			ui.box(
				"translation",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					font_size = TRANSLATION_FONT_SIZE,
					text_color = kit.colors.dim,
					flags = {.Wrap_Text},
				},
				line.translation,
			)
		}
	}
}

build_lead_note :: proc() {
	if lyrics_state.lead_changed_ms == 0 do return

	shown_seconds := (helper.now_ms() - lyrics_state.lead_changed_ms) / 1000
	if shown_seconds > LEAD_NOTE_SECONDS do return

	platform.request_frame_after(LEAD_NOTE_SECONDS - shown_seconds + TIMER_SLACK_SECONDS)

	text := fmt.tprintf(
		"The lyrics run %.2f s ahead of Music.app. Cmd [ and Cmd ] change it.",
		f64(lyrics_state.lead_ms) / 1000,
	)
	ui.box(
		"",
		{
			width = ui.fill(),
			height = ui.fit_text(),
			padding = {8, 8, 8, 8},
			corner_radius = 8,
			background = kit.colors.card,
			text_color = kit.colors.text,
			font_size = 12,
			flags = {.Floating, .Wrap_Text},
		},
		text,
	)
}
