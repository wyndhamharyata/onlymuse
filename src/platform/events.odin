package platform

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import NS "core:sys/darwin/Foundation"

Modifier :: enum {
	Shift,
	Control,
	Option,
	Command,
}

Modifiers :: bit_set[Modifier]

Mouse_Button :: enum {
	Left,
	Right,
	Middle,
}

// Positions are in points from the top left of the window.
Mouse_Move :: struct {
	position: [2]f32,
}

Mouse_Press :: struct {
	position:    [2]f32,
	button:      Mouse_Button,
	click_count: int,
	modifiers:   Modifiers,
}

Mouse_Release :: struct {
	position: [2]f32,
	button:   Mouse_Button,
}

Mouse_Exit :: struct {}

Scroll :: struct {
	position:    [2]f32,
	// Points for a trackpad, lines for a mouse wheel.
	delta:       [2]f32,
	is_precise:  bool,
	is_momentum: bool,
	// A finger touched the trackpad, starting a new swipe.
	is_start:    bool,
}

Key_Press :: struct {
	key_code:   u16,
	// Lives until the next frame.
	characters: string,
	modifiers:  Modifiers,
	is_repeat:  bool,
}

// Finished text from the keyboard or an input method.
Text_Insert :: struct {
	// Lives until the next frame.
	text: string,
}

// An input method's unfinished text, such as kana before it becomes kanji. Empty when it ends.
Text_Marked :: struct {
	text: string,
}

// An editing key, by AppKit's selector, such as "deleteBackward:", "insertNewline:" or "moveLeft:".
Text_Command :: struct {
	name: string,
}

Event :: union {
	Text_Insert,
	Text_Marked,
	Text_Command,
	Mouse_Move,
	Mouse_Press,
	Mouse_Release,
	Mouse_Exit,
	Scroll,
	Key_Press,
}

// The events since the last frame.
list_events :: proc() -> []Event {
	return state.events[:]
}

@(private)
to_modifiers :: proc(event: ^NS.Event) -> Modifiers {
	flags := transmute(NS.UInteger)event->modifierFlags()
	modifiers: Modifiers

	if flags & (1 << 17) != 0 do modifiers += {.Shift}
	if flags & (1 << 18) != 0 do modifiers += {.Control}
	if flags & (1 << 19) != 0 do modifiers += {.Option}
	if flags & (1 << 20) != 0 do modifiers += {.Command}

	return modifiers
}

@(private)
to_position :: proc(event: ^NS.Event) -> [2]f32 {
	location := event->locationInWindow()

	// An event with no window, such as one sent to the process, gives its place on the screen.
	if event->window() == nil do location = msg_send(NS.Point, state.ns_window, "convertPointFromScreen:", location)

	return {f32(location.x), state.window.size_points.y - f32(location.y)}
}

// Returns true when the event is ours alone, so AppKit never sees it.
@(private)
take_event :: proc(event: ^NS.Event) -> bool {
	event_window := event->window()
	if event_window != nil && event_window != state.ns_window do return false

	arena_allocator := runtime.arena_allocator(&state.event_arena[state.event_arena_index])
	is_taken := false

	#partial switch event->type() {
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		append(&state.events, Mouse_Move{to_position(event)})
	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		button := to_button(event)
		append(&state.events, Mouse_Press{to_position(event), button, int(event->clickCount()), to_modifiers(event)})
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		append(&state.events, Mouse_Release{to_position(event), to_button(event)})
	case .ApplicationDefined:
		request_frame()
		return true
	case .MouseExited:
		append(&state.events, Mouse_Exit{})
	case .ScrollWheel:
		momentum_phase := msg_send(NS.UInteger, event, "momentumPhase")
		// NSEventPhaseBegan and NSEventPhaseMayBegin.
		phase := msg_send(NS.UInteger, event, "phase")
		append(&state.events, Scroll {
			is_start    = phase == 1 || phase == 32,
			position    = to_position(event),
			delta       = {f32(event->scrollingDeltaX()), f32(event->scrollingDeltaY())},
			is_precise  = bool(event->hasPreciseScrollingDeltas()),
			is_momentum = momentum_phase != 0,
		})
	case .KeyDown:
		modifiers := to_modifiers(event)

		// A text field takes the key through the view's input method, except a shortcut.
		if state.is_text_input && .Command not_in modifiers && .Control not_in modifiers {
			request_frame()
			return false
		}

		characters := event->charactersIgnoringModifiers()->odinString()
		append(&state.events, Key_Press {
			key_code   = u16(event->keyCode()),
			characters = strings.clone(characters, arena_allocator),
			modifiers  = modifiers,
			is_repeat  = bool(event->isARepeat()),
		})
		is_taken = true
	case:
		return false
	}

	request_frame()

	return is_taken
}

@(private)
to_button :: proc(event: ^NS.Event) -> Mouse_Button {
	switch event->buttonNumber() {
	case 0:
		return .Left
	case 1:
		return .Right
	}

	return .Middle
}
