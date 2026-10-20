package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "om:font"
import "om:platform"
import "om:store"
import "om:ui"

SEARCH_FONT_SIZE :: 13

search_field: struct {
	text:            [dynamic]u8,
	// A byte index into text.
	cursor:          int,
	// An input method's unfinished text, shown at the cursor.
	marked:          string,
	is_focused:      bool,
	// After Cmd A, the next key replaces the whole text.
	is_all_selected: bool,
	is_hovered:      bool,
}

start_search_field :: proc() {
	if saved, ok := store.find_state("searchTerm", context.temp_allocator); ok {
		term: string
		if json.unmarshal_string(saved, &term, allocator = context.temp_allocator) == nil {
			append(&search_field.text, term)
			search_field.cursor = len(search_field.text)
		}
	}
}

@(private = "file")
field_text :: proc() -> string {
	return string(search_field.text[:])
}

@(private = "file")
save_term :: proc() {
	bytes, _ := json.marshal(field_text(), allocator = context.temp_allocator)
	store.save_state("searchTerm", string(bytes))
}

@(private = "file")
replace_all_if_selected :: proc() {
	if !search_field.is_all_selected do return

	clear(&search_field.text)
	search_field.cursor = 0
	search_field.is_all_selected = false
}

@(private = "file")
insert_text :: proc(text: string) {
	replace_all_if_selected()
	inject_at(&search_field.text, search_field.cursor, ..transmute([]u8)text)
	search_field.cursor += len(text)
	save_term()
}

@(private = "file")
previous_rune_start :: proc(index: int) -> int {
	if index <= 0 do return 0

	_, size := utf8.decode_last_rune(search_field.text[:index])

	return index - size
}

@(private = "file")
next_rune_end :: proc(index: int) -> int {
	if index >= len(search_field.text) do return len(search_field.text)

	_, size := utf8.decode_rune(search_field.text[index:])

	return index + size
}

@(private = "file")
delete_range :: proc(first, last: int) {
	if last <= first do return

	remove_range(&search_field.text, first, last)
	search_field.cursor = first
	save_term()
}

// The start of the word before index, as Option Backspace takes it.
@(private = "file")
previous_word_start :: proc(index: int) -> int {
	start := index
	for start > 0 && search_field.text[start - 1] == ' ' do start -= 1
	for start > 0 && search_field.text[start - 1] != ' ' do start = previous_rune_start(start)

	return start
}

@(private = "file")
apply_command :: proc(name: string) {
	text_length := len(search_field.text)
	cursor := search_field.cursor

	if search_field.is_all_selected && (name == "deleteBackward:" || name == "deleteForward:") {
		replace_all_if_selected()
		save_term()
		return
	}

	search_field.is_all_selected = false

	switch name {
	case "deleteBackward:":
		delete_range(previous_rune_start(cursor), cursor)
	case "deleteForward:":
		delete_range(cursor, next_rune_end(cursor))
	case "deleteWordBackward:":
		delete_range(previous_word_start(cursor), cursor)
	case "deleteToBeginningOfLine:":
		delete_range(0, cursor)
	case "moveLeft:":
		search_field.cursor = previous_rune_start(cursor)
	case "moveRight:":
		search_field.cursor = next_rune_end(cursor)
	case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveUp:", "moveToBeginningOfDocument:":
		search_field.cursor = 0
	case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveDown:", "moveToEndOfDocument:":
		search_field.cursor = text_length
	case "insertNewline:":
		term := strings.trim_space(field_text())
		if term != "" do navigate({kind = .Search, id = strings.clone(term)})
	case "cancelOperation:":
		search_field.is_focused = false
	}
}

// Takes the keyboard's text while the field is focused, and a click inside or outside it.
apply_search_events :: proc() {
	for event in platform.list_events() {
		#partial switch e in event {
		case platform.Mouse_Press:
			search_field.is_focused = search_field.is_hovered
		case platform.Text_Insert:
			if !search_field.is_focused do continue
			delete(search_field.marked)
			search_field.marked = ""
			// Return comes as a command, never as text.
			if e.text != "\\r" && e.text != "\\n" do insert_text(e.text)
		case platform.Text_Marked:
			if !search_field.is_focused do continue
			replace_all_if_selected()
			delete(search_field.marked)
			search_field.marked = strings.clone(e.text)
		case platform.Text_Command:
			if search_field.is_focused do apply_command(e.name)
		case platform.Key_Press:
			if !search_field.is_focused || .Command not_in e.modifiers do continue

			switch e.characters {
			case "a":
				search_field.is_all_selected = true
			case "v":
				insert_text(strings.trim_space(platform.read_clipboard()))
			}
		}
	}
}

build_search_field :: proc() {
	is_focused := search_field.is_focused
	field := ui.box("search", {
		width         = ui.fill(),
		height        = ui.points(30),
		axis          = .X,
		align         = .Center,
		gap           = 7,
		padding       = {9, 0, 9, 0},
		corner_radius = 8,
		background    = colors.field,
		border_width  = 1 if is_focused else 0,
		border_color  = to_accent_tint(app.accent) * {1, 1, 1, 3},
		flags         = {.Clickable},
	})
	search_field.is_hovered = ui.signal(field).is_hovered

	if ui.scope(field) {
		icon_box("", "magnifyingglass", 13, colors.faint)

		text := field_text()
		cursor := search_field.cursor
		shown := fmt.tprintf("%s%s%s", text[:cursor], search_field.marked, text[cursor:])
		is_empty := shown == ""
		line := ui.box("line", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint if is_empty else colors.text, font_size = SEARCH_FONT_SIZE, flags = {.Clip}}, "Search" if is_empty else shown)

		if search_field.is_all_selected && !is_empty do line.style.background = to_accent_tint(app.accent)

		if is_focused {
			if ui.scope(line) do build_caret(line, text[:cursor], search_field.marked)
		}
	}

	if !is_focused do platform.set_text_input(false)

	ui.box("", {width = ui.fill(), height = ui.points(6)})
}

// The caret after the cursor, and a line under unfinished text. Widths come from the shaped text, in points.
@(private = "file")
build_caret :: proc(line: ^ui.Box, before, marked: string) {
	font_now := font.system_font(.Regular, ui.to_pixels(SEARCH_FONT_SIZE))
	to_width :: proc(text: string, font_now: font.Font) -> f32 {
		if text == "" do return 0
		return font.shape(text, font_now).size.x / ui.to_pixels(1)
	}

	before_width := to_width(before, font_now)
	marked_width := to_width(marked, font_now)
	height := line.rect.w - line.rect.y

	if marked != "" {
		ui.box("", {width = ui.points(marked_width), height = ui.points(1), background = colors.text, position = {before_width, height - 1}, flags = {.Floating}})
	}

	caret_x := before_width + marked_width
	ui.box("", {width = ui.points(1.5), height = ui.points(height), background = app.accent, position = {caret_x, 0}, flags = {.Floating}})

	// The input method's candidates open under the caret. The rect is in window points.
	zoom := app.zoom
	caret := [4]f32{line.rect.x + before_width, line.rect.y, line.rect.x + caret_x + 2, line.rect.w} * zoom
	platform.set_text_input(true, caret)
}
