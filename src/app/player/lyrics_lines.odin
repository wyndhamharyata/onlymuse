package player

import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:helper"
import "om:lyrics"
import "om:platform"
import "om:ui"

// Returns how far a moment's fade went, from 0 when it starts to 1 after WORD_FADE_SECONDS.
to_fade :: proc(begin_seconds: f64) -> f32 {
	return f32(clamp((lyrics_state.position_seconds - begin_seconds) / WORD_FADE_SECONDS, 0, 1))
}

Line_Paint :: struct {
	index: int,
	words: []lyrics.Word,
}

// The sung words of the current line fade into the accent. Those of the line before fade back as the next line starts.
color_lyric_glyph :: proc(utf16_index: int, data: rawptr) -> [4]f32 {
	paint := cast(^Line_Paint)data
	current := lyrics_state.current_index
	lit: f32

	for word in paint.words {
		if utf16_index < word.utf16_range.x || utf16_index >= word.utf16_range.y do continue

		if paint.index == current {
			lit = to_fade(word.begin_seconds)
		} else if paint.index == current - 1 &&
		   word.begin_seconds <= lyrics_state.position_seconds {
			lit = 1 - to_fade(lyrics_state.lines[current].begin_seconds)
		}

		break
	}

	return kit.colors.dim + (core.app.accent - kit.colors.dim) * lit
}

build_lyric_line :: proc(line: ^lyrics.Line, index: int) {
	is_current := index == lyrics_state.current_index
	opacity := ui.animate(
		fmt.tprintf("lyric opacity %d", index),
		1 if is_current else OTHER_LINE_OPACITY,
		LINE_FADE_RATE,
	)
	line_box := ui.box(
		fmt.tprintf("line %d", index),
		{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2, fade = 1 - opacity},
	)

	if ui.scope(line_box) {
		paint := new(Line_Paint, context.temp_allocator)
		paint^ = {index, line.words}

		text := ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				font_size = LYRIC_FONT_SIZE,
				font_weight = .Bold,
				text_color = kit.colors.dim,
				flags = {.Wrap_Text},
			},
			line.text,
		)
		text.color_of = color_lyric_glyph
		text.data = paint

		if line.pronunciation != "" && lyrics_state.is_showing_romaji {
			pronunciation_paint := new(Line_Paint, context.temp_allocator)
			pronunciation_paint^ = {index, line.pronunciation_words}

			pronunciation := ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					font_size = PRONUNCIATION_FONT_SIZE,
					font_weight = .Bold,
					text_color = kit.colors.dim,
					flags = {.Wrap_Text},
				},
				line.pronunciation,
			)
			pronunciation.color_of = color_lyric_glyph
			pronunciation.data = pronunciation_paint
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

// After Cmd [ or Cmd ], this shows the new lead for a moment, so the person hears the change against a number.
build_lead_note :: proc() {
	if lyrics_state.lead_changed_ms == 0 do return

	shown_seconds := (helper.now_ms() - lyrics_state.lead_changed_ms) / 1000
	if shown_seconds > LEAD_NOTE_SECONDS do return

	platform.request_frame_after(LEAD_NOTE_SECONDS - shown_seconds + 0.01)

	text := fmt.tprintf(
		"Lyrics %.2f s ahead of Music.app. Cmd [ and Cmd ] change it.",
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
