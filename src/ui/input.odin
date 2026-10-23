package ui

import "om:platform"

SWIPE_DECIDE_POINTS :: 4

SWIPE_SIDEWAYS_RATIO :: 1.5

@(private)
apply_events :: proc() {
	for item in platform.list_events() {
		switch event in item {
		case platform.Mouse_Move:
			state.mouse = event.position / state.zoom
		case platform.Mouse_Press:
			state.mouse = event.position / state.zoom

			if event.button == .Right || .Control in event.modifiers {
				state.right_clicked_key = state.hot_key
				state.is_right_press = true
				continue
			}

			state.press_position = state.mouse
			state.active_key = state.hot_key
			state.pressed_key = state.hot_key
		case platform.Mouse_Release:
			if state.is_right_press {
				state.is_right_press = false
				continue
			}

			if state.active_key != 0 && state.active_key == state.hot_key {
				state.clicked_key = state.active_key
			}

			state.active_key = 0
		case platform.Mouse_Exit:
			state.mouse = {-1, -1}
		case platform.Scroll:
			apply_scroll(event)
		case platform.Key_Press, platform.Text_Insert, platform.Text_Marked, platform.Text_Command:
		}
	}
}

@(private)
apply_scroll :: proc(event: platform.Scroll) {
	delta := event.delta / state.zoom if event.is_precise else event.delta * POINTS_PER_LINE

	if event.is_start {
		state.swipe_axis = nil
		state.undecided_swipe_points = {}
	}

	if event.is_precise {
		axis, is_known := state.swipe_axis.?

		if !is_known {
			state.undecided_swipe_points += delta

			undecided := state.undecided_swipe_points
			if abs(undecided.x) + abs(undecided.y) < SWIPE_DECIDE_POINTS do return

			axis = .X if abs(undecided.x) > abs(undecided.y) * SWIPE_SIDEWAYS_RATIO else .Y
			state.swipe_axis = axis
			delta = undecided
		}

		delta[1 - int(axis)] = 0
	}

	for axis in Axis {
		box, ok := state.boxes[state.scroll_keys[axis]]
		is_scrolled := ok && delta[int(axis)] != 0

		if !is_scrolled do continue

		box.scroll_target -= delta[int(axis)]
		// macOS already supplies the glide after a trackpad flick.
		if event.is_precise do box.scroll = box.scroll_target
	}
}

Signal :: struct {
	is_hovered:       bool,
	is_held:          bool,
	is_clicked:       bool,
	is_right_clicked: bool,
}

signal :: proc(box: ^Box) -> Signal {
	is_kept := box.key != 0

	return Signal {
		is_hovered = is_kept && box.key == state.hot_key,
		is_held = is_kept && box.key == state.active_key,
		is_clicked = is_kept && box.key == state.clicked_key,
		is_right_clicked = is_kept && box.key == state.right_clicked_key,
	}
}

press_position :: proc() -> ([2]f32, bool) {
	return state.press_position, state.active_key != 0
}

mouse_position :: proc() -> [2]f32 {
	return state.mouse
}

@(private)
is_inside :: proc(point: [2]f32, rect: [4]f32) -> bool {
	return point.x >= rect.x && point.x < rect.z && point.y >= rect.y && point.y < rect.w
}

@(private)
apply_mouse_to_boxes :: proc() {
	state.hot_key = 0
	state.scroll_keys = {}
	visit_hot(state.root)

	for _, box in state.boxes {
		is_hot :=
			box.key == state.hot_key && (state.active_key == 0 || state.active_key == box.key)

		box.hot_fraction = approach(box.hot_fraction, 1 if is_hot else 0, HOT_RATE_PER_SECOND)
		box.active_fraction = approach(
			box.active_fraction,
			1 if box.key == state.active_key else 0,
			HOT_RATE_PER_SECOND,
		)
	}
}

@(private)
visit_hot :: proc(box: ^Box) {
	flags := box.style.flags
	is_under_mouse := is_inside(state.mouse, intersect(box.rect, box.clip))
	is_clipped_away := !is_under_mouse && .Clip in flags
	is_kept_under_mouse := is_under_mouse && box.key != 0
	is_hoverable := .Clickable in flags || .Hoverable in flags

	if is_clipped_away do return

	if is_kept_under_mouse {
		if is_hoverable do state.hot_key = box.key
		if .Scroll in flags do state.scroll_keys[box.style.axis] = box.key
	}

	for child := box.first; child != nil; child = child.next do visit_hot(child)
}
