package kit

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "om:app/core"
import "om:platform"
import "om:ui"

TEXT_FIELD_FONT_SIZE :: 13

FOCUS_BORDER_ALPHA :: 3 * ACCENT_TINT_ALPHA

Text_Field :: struct {
	text:              [dynamic]u8,
	cursor:            int,
	marked:            string,
	is_focused:        bool,
	is_all_selected:   bool,
	is_hovered:        bool,
	is_keeping_focus:  bool,
	is_taking_up_down: bool,
	is_changed:        bool,
	is_submitted:      bool,
	is_cancelled:      bool,
	step:              int,
}

@(private = "file")
text_fields: [dynamic]^Text_Field

@(private = "file")
caret_rect: [4]f32

register_text_field :: proc(field: ^Text_Field) {
	append(&text_fields, field)
}

to_field_text :: proc(field: ^Text_Field) -> string {
	return string(field.text[:])
}

set_field_text :: proc(field: ^Text_Field, text: string) {
	clear(&field.text)
	append(&field.text, text)
	field.cursor = len(field.text)
	field.is_all_selected = false
}

focus_field :: proc(field: ^Text_Field) {
	for other in text_fields do other.is_focused = false
	field.is_focused = true
}

@(private = "file")
replace_all_if_selected :: proc(field: ^Text_Field) {
	if !field.is_all_selected do return

	clear(&field.text)
	field.cursor = 0
	field.is_all_selected = false
	field.is_changed = true
}

@(private = "file")
insert_text :: proc(field: ^Text_Field, text: string) {
	replace_all_if_selected(field)
	inject_at(&field.text, field.cursor, ..transmute([]u8)text)
	field.cursor += len(text)
	field.is_changed = true
}

@(private = "file")
to_previous_rune_start :: proc(field: ^Text_Field, index: int) -> int {
	if index <= 0 do return 0

	_, size := utf8.decode_last_rune(field.text[:index])

	return index - size
}

@(private = "file")
to_next_rune_end :: proc(field: ^Text_Field, index: int) -> int {
	if index >= len(field.text) do return len(field.text)

	_, size := utf8.decode_rune(field.text[index:])

	return index + size
}

@(private = "file")
delete_range :: proc(field: ^Text_Field, start, end: int) {
	if end <= start do return

	remove_range(&field.text, start, end)
	field.cursor = start
	field.is_changed = true
}

@(private = "file")
to_previous_word_start :: proc(field: ^Text_Field, index: int) -> int {
	start := index
	for start > 0 && field.text[start - 1] == ' ' do start -= 1
	for start > 0 && field.text[start - 1] != ' ' do start = to_previous_rune_start(field, start)

	return start
}

@(private = "file")
apply_command :: proc(field: ^Text_Field, name: string) {
	cursor := field.cursor
	is_delete_key := name == "deleteBackward:" || name == "deleteForward:"

	if field.is_all_selected && is_delete_key {
		replace_all_if_selected(field)
		return
	}

	field.is_all_selected = false

	switch name {
	case "deleteBackward:":
		delete_range(field, to_previous_rune_start(field, cursor), cursor)
	case "deleteForward:":
		delete_range(field, cursor, to_next_rune_end(field, cursor))
	case "deleteWordBackward:":
		delete_range(field, to_previous_word_start(field, cursor), cursor)
	case "deleteToBeginningOfLine:":
		delete_range(field, 0, cursor)
	case "insertNewline:":
		field.is_submitted = true
	case "cancelOperation:":
		field.is_cancelled = true
		field.is_focused = false
	case:
		apply_move_command(field, name)
	}
}

@(private = "file")
apply_move_command :: proc(field: ^Text_Field, name: string) {
	cursor := field.cursor

	switch name {
	case "moveLeft:":
		field.cursor = to_previous_rune_start(field, cursor)
	case "moveRight:":
		field.cursor = to_next_rune_end(field, cursor)
	case "moveUp:":
		if field.is_taking_up_down do field.step = -1
		else do field.cursor = 0
	case "moveDown:":
		if field.is_taking_up_down do field.step = 1
		else do field.cursor = len(field.text)
	case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveToBeginningOfDocument:":
		field.cursor = 0
	case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfDocument:":
		field.cursor = len(field.text)
	}
}

apply_text_events :: proc() {
	for field in text_fields {
		field.is_changed = false
		field.is_submitted = false
		field.is_cancelled = false
		field.step = 0
	}

	for event in platform.list_events() {
		#partial switch input in event {
		case platform.Mouse_Press:
			focus_hovered_field()
		case platform.Text_Insert:
			field := find_focused_field() or_continue
			delete(field.marked)
			field.marked = ""
			// Return comes as a command, never as text.
			if input.text != "\r" && input.text != "\n" do insert_text(field, input.text)
		case platform.Text_Marked:
			field := find_focused_field() or_continue
			replace_all_if_selected(field)
			delete(field.marked)
			field.marked = strings.clone(input.text)
		case platform.Text_Command:
			field := find_focused_field() or_continue
			apply_command(field, input.name)
		case platform.Key_Press:
			field := find_focused_field() or_continue
			if .Command not_in input.modifiers do continue

			switch input.characters {
			case "a":
				field.is_all_selected = true
			case "v":
				insert_text(field, strings.trim_space(platform.read_clipboard()))
			}
		}
	}

	for field in text_fields do field.is_hovered = false
}

@(private = "file")
focus_hovered_field :: proc() {
	for field in text_fields {
		if field.is_hovered {
			focus_field(field)
		} else if !field.is_keeping_focus {
			field.is_focused = false
		}
	}
}

find_focused_field :: proc() -> (^Text_Field, bool) {
	for field in text_fields do if field.is_focused do return field, true

	return nil, false
}

finish_text_fields :: proc() {
	_, is_focused := find_focused_field()
	platform.set_text_input(is_focused, caret_rect)
}

build_text_field :: proc(
	field: ^Text_Field,
	id, placeholder, symbol: string,
	height: f32 = 30,
	font_size: f32 = TEXT_FIELD_FONT_SIZE,
	background := [4]f32{},
) {
	is_focused := field.is_focused
	box := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.points(height),
			axis = .X,
			align = .Center,
			gap = 7,
			padding = {9, 0, 9, 0},
			corner_radius = 8,
			background = background if background.a > 0 else colors.field,
			border_width = 1 if is_focused else 0,
			border_color = to_faded(core.app.accent, FOCUS_BORDER_ALPHA),
			flags = {.Clickable},
		},
	)

	field.is_hovered = ui.signal(box).is_hovered

	if ui.scope(box) {
		if symbol != "" do icon_box("", symbol, font_size, colors.faint)

		text := to_field_text(field)
		cursor := field.cursor
		shown := fmt.tprintf("%s%s%s", text[:cursor], field.marked, text[cursor:])
		is_empty := shown == ""
		is_text_selected := field.is_all_selected && !is_empty

		line := ui.box(
			"line",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = colors.faint if is_empty else colors.text,
				background = to_accent_tint(core.app.accent) if is_text_selected else {},
				font_size = font_size,
				flags = {.Clip},
			},
			placeholder if is_empty else shown,
		)

		if !is_focused do return
		if ui.scope(line) do build_caret(line, text[:cursor], field.marked, font_size)
	}
}

@(private = "file")
build_caret :: proc(line: ^ui.Box, before, marked: string, font_size: f32) {
	before_width := measure_text(before, font_size)
	marked_width := measure_text(marked, font_size)
	height := line.rect.w - line.rect.y

	if marked != "" {
		ui.box(
			"",
			{
				width = ui.points(marked_width),
				height = ui.points(1),
				background = colors.text,
				position = {before_width, height - 1},
				flags = {.Floating},
			},
		)
	}

	caret_x := before_width + marked_width

	ui.box(
		"",
		{
			width = ui.points(1.5),
			height = ui.points(height),
			background = core.app.accent,
			position = {caret_x, 0},
			flags = {.Floating},
		},
	)

	caret_rect =
		[4]f32{line.rect.x + before_width, line.rect.y, line.rect.x + caret_x + 2, line.rect.w} *
		core.app.zoom
}
