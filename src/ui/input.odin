package ui

import "om:platform"

// A swipe picks its axis once it moves this far.
SWIPE_DECIDE_POINTS :: 4

// A swipe goes sideways only when it goes this much more sideways than up or down.
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
			state.click_count = event.click_count
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
			delta :=
				event.delta / state.zoom if event.is_precise else event.delta * POINTS_PER_LINE

			if event.is_start {
				state.swipe_axis = nil
				state.swipe_pending = {}
			}

			if event.is_precise {
				axis, is_known := state.swipe_axis.?

				if !is_known {
					state.swipe_pending += delta

					pending := state.swipe_pending
					if abs(pending.x) + abs(pending.y) < SWIPE_DECIDE_POINTS do continue

					axis = .X if abs(pending.x) > abs(pending.y) * SWIPE_SIDEWAYS_RATIO else .Y
					state.swipe_axis = axis
					delta = pending
				}

				delta[1 - int(axis)] = 0
			}

			for axis in Axis {
				box, ok := state.boxes[state.scroll_keys[axis]]
				if !ok || delta[int(axis)] == 0 do continue

				box.scroll_target -= delta[int(axis)]
				// A trackpad already moves smoothly. macOS puts in the glide after a flick.
				if event.is_precise do box.scroll = box.scroll_target
			}
		// The app's shortcuts and text fields read the keys themselves.
		case platform.Key_Press, platform.Text_Insert, platform.Text_Marked, platform.Text_Command:
		}
	}
}

// Where the left button went down, and whether it is down now.
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

// The last box drawn under the mouse takes it. That box shows on top.
@(private)
find_hot :: proc() {
	state.hot_key = 0
	state.scroll_keys = {}
	visit_hot(state.root)

	for _, box in state.boxes {
		is_hot :=
			box.key == state.hot_key && (state.active_key == 0 || state.active_key == box.key)

		box.hot_fraction = approach(box.hot_fraction, 1 if is_hot else 0, HOT_RATE)
		box.active_fraction = approach(
			box.active_fraction,
			1 if box.key == state.active_key else 0,
			HOT_RATE,
		)
	}
}

@(private)
visit_hot :: proc(box: ^Box) {
	is_under_mouse := is_inside(state.mouse, intersect(box.rect, box.clip))

	if !is_under_mouse && .Clip in box.style.flags do return

	if is_under_mouse && box.key != 0 {
		if .Clickable in box.style.flags || .Hoverable in box.style.flags do state.hot_key = box.key
		if .Scroll in box.style.flags do state.scroll_keys[box.style.axis] = box.key
	}

	for child := box.first; child != nil; child = child.next do visit_hot(child)
}
