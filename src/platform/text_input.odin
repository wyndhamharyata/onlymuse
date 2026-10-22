package platform

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:unicode/utf8"

// This 1-point view takes the keys while a text field has focus. An input method composes in it.
// The Metal view cannot. Its layer then gets a 0 by 0 drawable once the window comes in front.
@(objc_class = "OMInputView", objc_superclass = NS.View, objc_implement)
Text_View :: struct {
	// using embeds NS.View, so a ^Text_View can stand in for a ^NS.View.
	using _: NS.View,
}

// objc_name makes this procedure the view's acceptsFirstResponder method. It says yes only while
// a field has focus, so AppKit never makes the view first responder when the window opens.
@(objc_type = Text_View, objc_implement, objc_name = "acceptsFirstResponder")
Text_View_acceptsFirstResponder :: proc "c" (self: ^Text_View) -> NS.BOOL {
	return NS.BOOL(state.is_text_input)
}

@(objc_type = Text_View, objc_implement, objc_name = "keyDown", objc_selector = "keyDown:")
Text_View_keyDown :: proc "c" (self: ^Text_View, event: ^NS.Event) {
	object := cast(^NS.Object)event
	events := NS.Array.alloc()->initWithObjects(&object, 1)

	// objc_send calls interpretKeyEvents:, which passes the key to the input method.
	objc_send(nil, self, "interpretKeyEvents:", events)
	events->release()
}

// @(private) keeps this procedure inside the platform package.
@(private)
to_odin_text :: proc "c" (text: ^NS.Object) -> string {
	// A proc "c" starts with no Odin context. This sets the one that open_window saved.
	context = state.odin_context
	plain := text

	// An input method may send an NSAttributedString.
	if objc_send(NS.BOOL, text, "respondsToSelector:", intrinsics.objc_find_selector("string")) {
		plain = objc_send(^NS.Object, text, "string")
	}

	return strings.clone(
		(cast(^NS.String)plain)->odinString(),
		runtime.arena_allocator(&state.event_arena[state.event_arena_index]),
	)
}

// NSResponder's insertText:, which AppKit calls when the view has no input context.
@(objc_type = Text_View, objc_implement, objc_name = "insertTextPlain", objc_selector = "insertText:")
Text_View_insertTextPlain :: proc "c" (self: ^Text_View, text: ^NS.Object) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Insert{to_odin_text(text)})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "insertText", objc_selector = "insertText:replacementRange:")
Text_View_insertText :: proc "c" (self: ^Text_View, text: ^NS.Object, replacement: NS.Range) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Insert{to_odin_text(text)})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "setMarkedText", objc_selector = "setMarkedText:selectedRange:replacementRange:")
Text_View_setMarkedText :: proc "c" (
	self: ^Text_View,
	text: ^NS.Object,
	selected, replacement: NS.Range,
) {
	context = state.odin_context
	marked := to_odin_text(text)

	state.marked_length = len(marked)
	append(&state.events, Text_Marked{marked})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "unmarkText")
Text_View_unmarkText :: proc "c" (self: ^Text_View) {
	context = state.odin_context
	state.marked_length = 0
	append(&state.events, Text_Marked{})
	request_frame()
}

@(objc_type = Text_View, objc_implement, objc_name = "hasMarkedText")
Text_View_hasMarkedText :: proc "c" (self: ^Text_View) -> NS.BOOL {
	return state.marked_length > 0
}

// NSNotFound marks no range.
@(private)
NOT_FOUND :: NS.UInteger(max(int))

@(objc_type = Text_View, objc_implement, objc_name = "markedRange")
Text_View_markedRange :: proc "c" (self: ^Text_View) -> NS.Range {
	if state.marked_length == 0 do return {NOT_FOUND, 0}

	return {0, NS.UInteger(state.marked_length)}
}

@(objc_type = Text_View, objc_implement, objc_name = "selectedRange")
Text_View_selectedRange :: proc "c" (self: ^Text_View) -> NS.Range {
	return {NOT_FOUND, 0}
}

@(objc_type = Text_View, objc_implement, objc_name = "validAttributesForMarkedText")
Text_View_validAttributesForMarkedText :: proc "c" (self: ^Text_View) -> ^NS.Array {
	return objc_send(^NS.Array, NS.Array, "array")
}

@(objc_type = Text_View, objc_implement, objc_name = "attributedSubstringForProposedRange", objc_selector = "attributedSubstringForProposedRange:actualRange:")
Text_View_attributedSubstringForProposedRange :: proc "c" (
	self: ^Text_View,
	range: NS.Range,
	actual: ^NS.Range,
) -> ^NS.Object {
	return nil
}

@(objc_type = Text_View, objc_implement, objc_name = "characterIndexForPoint", objc_selector = "characterIndexForPoint:")
Text_View_characterIndexForPoint :: proc "c" (self: ^Text_View, point: NS.Point) -> NS.UInteger {
	return NOT_FOUND
}

// The input method opens its list of candidates at this rect, under the caret, on the screen.
@(objc_type = Text_View, objc_implement, objc_name = "firstRectForCharacterRange", objc_selector = "firstRectForCharacterRange:actualRange:")
Text_View_firstRectForCharacterRange :: proc "c" (
	self: ^Text_View,
	range: NS.Range,
	actual: ^NS.Range,
) -> NS.Rect {
	caret := state.caret_rect
	height := f64(state.window.size_points.y)
	in_window := NS.Rect {
		{NS.Float(caret.x), NS.Float(height - f64(caret.w))},
		{NS.Float(caret.z - caret.x), NS.Float(caret.w - caret.y)},
	}

	return objc_send(NS.Rect, state.ns_window, "convertRectToScreen:", in_window)
}

@(objc_type = Text_View, objc_implement, objc_name = "doCommandBySelector", objc_selector = "doCommandBySelector:")
Text_View_doCommandBySelector :: proc "c" (self: ^Text_View, selector: NS.SEL) {
	context = state.odin_context
	name := string(sel_getName(selector))

	append(
		&state.events,
		Text_Command {
			strings.clone(
				name,
				runtime.arena_allocator(&state.event_arena[state.event_arena_index]),
			),
		},
	)
	request_frame()
}

// Turns the keyboard over to a text field, or back to the app's shortcuts.
set_text_input :: proc(is_on: bool, caret_rect: [4]f32 = {}) {
	state.caret_rect = caret_rect
	if is_on == state.is_text_input do return

	state.is_text_input = is_on

	if is_on {
		objc_send(NS.BOOL, state.ns_window, "makeFirstResponder:", state.input_view)
	} else {
		state.marked_length = 0
		objc_send(
			nil,
			objc_send(^NS.Object, state.input_view, "inputContext"),
			"discardMarkedText",
		)
		objc_send(NS.BOOL, state.ns_window, "makeFirstResponder:", rawptr(nil))
	}
}

// The tests type with this. A window behind the others gets no keys from the keyboard.
// It sends each character as a key press to the view's input context. It returns false without one.
type_for_test :: proc(text: string) -> bool {
	input_context := objc_send(^NS.Object, state.input_view, "inputContext")
	has_context := input_context != nil

	// AppKit activates the context of the key window's first responder. A test window is never key.
	if has_context do objc_send(nil, input_context, "activate")

	window_number := objc_send(NS.Integer, state.ns_window, "windowNumber")

	for character in text {
		buffer, size := utf8.encode_rune(character)
		ns_character := NS.String.alloc()->initWithOdinString(string(buffer[:size]))
		// defer runs release at the end of each pass of the loop.
		defer ns_character->release()

		// NSEventTypeKeyDown is 10.
		event := objc_send(
			^NS.Event,
			NS.Event,
			"keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
			NS.UInteger(10),
			NS.Point{},
			NS.UInteger(0),
			NS.TimeInterval(0),
			window_number,
			rawptr(nil),
			ns_character,
			ns_character,
			NS.BOOL(false),
			u16(0),
		)

		objc_send(nil, state.input_view, "keyDown:", event)
	}

	return has_context
}
