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

Mouse_Move :: struct {
	position: [2]f32,
}

Mouse_Press :: struct {
	position:  [2]f32,
	button:    Mouse_Button,
	modifiers: Modifiers,
}

Mouse_Release :: struct {
	button: Mouse_Button,
}

Mouse_Exit :: struct {
}

Scroll :: struct {
	// The delta is in points for a trackpad and in lines for a mouse wheel.
	delta:      [2]f32,
	is_precise: bool,
	is_start:   bool,
}

Key_Press :: struct {
	key_code:   u16,
	characters: string,
	modifiers:  Modifiers,
}

Text_Insert :: struct {
	text: string,
}

Text_Marked :: struct {
	text: string,
}

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
read_position :: proc(event: ^NS.Event) -> [2]f32 {
	location := event->locationInWindow()

	if event->window() == nil {
		location = objc_send(NS.Point, state.ns_window, "convertPointFromScreen:", location)
	}

	return {f32(location.x), state.window.size_points.y - f32(location.y)}
}

@(private)
apply_event :: proc(event: ^NS.Event) -> bool {
	event_window := event->window()

	if event_window != nil && event_window != state.ns_window do return false

	is_taken := false

	#partial switch event->type() {
	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		append(&state.events, Mouse_Move{read_position(event)})
	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		button := to_button(event)

		append(&state.events, Mouse_Press{read_position(event), button, to_modifiers(event)})
	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		append(&state.events, Mouse_Release{to_button(event)})
	case .ApplicationDefined:
		request_frame()
		return true
	case .MouseExited:
		append(&state.events, Mouse_Exit{})
	case .ScrollWheel:
		// The phases 1 and 32 are NSEventPhaseBegan and NSEventPhaseMayBegin.
		phase := objc_send(NS.UInteger, event, "phase")

		append(
			&state.events,
			Scroll {
				is_start = phase == 1 || phase == 32,
				delta = {f32(event->scrollingDeltaX()), f32(event->scrollingDeltaY())},
				is_precise = bool(event->hasPreciseScrollingDeltas()),
			},
		)
	case .KeyDown:
		modifiers := to_modifiers(event)
		is_typing := state.is_text_input && .Command not_in modifiers && .Control not_in modifiers

		if is_typing {
			request_frame()
			return false
		}

		characters := event->charactersIgnoringModifiers()->odinString()

		append(
			&state.events,
			Key_Press {
				key_code = u16(event->keyCode()),
				characters = strings.clone(characters, event_allocator()),
				modifiers = modifiers,
			},
		)
		is_taken = true
	case:
		return false
	}

	request_frame()

	return is_taken
}

@(private)
event_allocator :: proc() -> runtime.Allocator {
	return runtime.arena_allocator(&state.event_arena[state.event_arena_index])
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
