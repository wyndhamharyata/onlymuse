// Immediate mode UI after Ryan Fleury's: the app builds a tree of boxes every frame, and a cache keyed by
// each box's ID keeps its state from one frame to the next.
package ui

import "core:hash"
import "core:math"
import "om:font"
import "om:platform"
import "om:render"

Axis :: enum {
	X,
	Y,
}

Size_Kind :: enum {
	Points,
	// The text and the padding.
	Text,
	// A share of the parent, without its padding.
	Percent,
	// The children laid along the axis, or the largest one across it.
	Children,
	// What is left in the parent along its axis, shared by weight. Across it, the whole parent.
	Fill,
}

Size :: struct {
	kind:  Size_Kind,
	value: f32,
}

points :: proc "contextless" (value: f32) -> Size {return {.Points, value}}
percent :: proc "contextless" (value: f32) -> Size {return {.Percent, value}}
fill :: proc "contextless" (weight: f32 = 1) -> Size {return {.Fill, weight}}
fit_children :: proc "contextless" () -> Size {return {.Children, 0}}
fit_text :: proc "contextless" () -> Size {return {.Text, 0}}

Align :: enum {
	Start,
	Center,
	End,
}

Flag :: enum {
	// Takes hover, press and click.
	Clickable,
	// Takes hover only, such as a title that slides to show the rest.
	Hoverable,
	// Scrolls its children along its axis.
	Scroll,
	// Hides children outside its rect.
	Clip,
	// Placed at style.position in its parent, out of the flow.
	Floating,
	// Glides to a new place instead of jumping.
	Animate_Position,
	Wrap_Text,
	// One line that ends in an ellipsis when it is too long.
	Truncate_Text,
	// A row whose children go on to a new line when the next one does not fit, such as pills.
	Wrap_Children,
}
Flags :: bit_set[Flag]

Style :: struct {
	width, height:    Size,
	axis:             Axis,
	// Left, top, right, bottom.
	padding:          [4]f32,
	gap:              f32,
	// Of the children across the axis.
	align:            Align,
	text_align:       Align,
	// Moves the text left by this many points, inside its clip.
	text_offset:      f32,
	background:       [4]f32,
	// How far the edge blurs, in points, for a shadow.
	softness:         f32,
	// The background fades to this colour between the two shares of the height in gradient.
	end_background:   [4]f32,
	gradient:         [2]f32,
	hover_background: [4]f32,
	press_background: [4]f32,
	border_color:     [4]f32,
	border_width:     f32,
	corner_radius:    f32,
	text_color:       [4]f32,
	font_weight:      font.Weight,
	font_size:        f32,
	// 0 draws the box as it is, 1 hides it and its children.
	fade:             f32,
	position:         [2]f32,
	flags:            Flags,
}

// Draws what a style cannot, such as an image. Rects are in pixels.
Draw_Proc :: proc(box: ^Box, rect, clip: [4]f32, opacity: f32)

Box :: struct {
	key:              u64,
	parent:           ^Box,
	first, last:      ^Box,
	next:             ^Box,
	style:            Style,
	text:             string,
	draw:             Draw_Proc,
	// Colours the text per character instead of style.text_color.
	color_of:         font.Color_Proc,
	data:             rawptr,
	last_built_frame: int,
	// Layout, in points from the top left of the window.
	size:             [2]f32,
	rect:             [4]f32,
	clip:             [4]f32,
	content_size:     [2]f32,
	shaped:           ^font.Shaped_Text,
	// Kept between frames.
	hot_t:            f32,
	active_t:         f32,
	scroll:           f32,
	scroll_target:    f32,
	shown_rect:       [4]f32,
	is_shown:         bool,
}

Signal :: struct {
	box:              ^Box,
	is_hovered:       bool,
	is_held:          bool,
	is_clicked:       bool,
	// The right button, or a Control click, which never presses or clicks.
	is_right_clicked: bool,
	click_count:    int,
}

@(private)
Animated_Value :: struct {
	value:            f32,
	last_built_frame: int,
}

// Hover and press fade in at this rate, per second.
HOT_RATE :: 20
// Points a mouse wheel moves per line.
POINTS_PER_LINE :: 40
@(private)
SETTLED :: 0.002

@(private)
state: struct {
	boxes:           map[u64]^Box,
	values:          map[u64]Animated_Value,
	root:            ^Box,
	parents:         [dynamic]^Box,
	frame_index:     int,
	scale:           f32,
	zoom:            f32,
	dt_seconds:      f32,
	mouse:           [2]f32,
	hot_key:         u64,
	active_key:      u64,
	// The box under the mouse that scrolls along each axis.
	scroll_keys:     [Axis]u64,
	// A trackpad swipe and its glide move along one axis, the one its first points went most along.
	swipe_axis:      Maybe(Axis),
	// The swipe's points before its axis is known.
	swipe_pending:   [2]f32,
	clicked_key:     u64,
	right_clicked_key: u64,
	// The button down is a right click's, so its release clicks nothing.
	is_right_press:  bool,
	// Where the left button went down, for a drag.
	press_position:  [2]f32,
	pressed_key:     u64,
	click_count:     int,
	is_animating:    bool,
}

// A swipe's axis is picked once it has moved this far.
SWIPE_DECIDE_POINTS :: 4
// A swipe goes sideways only when it goes this much more sideways than up or down.
SWIPE_SIDEWAYS_RATIO :: 1.5

// Points are window points divided by zoom. scale turns points into pixels.
begin_frame :: proc(window_size_points: [2]f32, pixels_per_point, zoom, dt_seconds: f32) {
	state.frame_index += 1
	state.zoom = zoom
	state.scale = pixels_per_point * zoom
	state.dt_seconds = min(dt_seconds, 1.0 / 30)
	state.clicked_key = 0
	state.right_clicked_key = 0
	state.pressed_key = 0
	state.is_animating = false

	apply_events()

	clear(&state.parents)
	state.root = make_box(0, {width = points(window_size_points.x / zoom), height = points(window_size_points.y / zoom)})
	append(&state.parents, state.root)
}

@(private)
apply_events :: proc() {
	for event in platform.list_events() {
		switch e in event {
		case platform.Mouse_Move:
			state.mouse = e.position / state.zoom
		case platform.Mouse_Press:
			state.mouse = e.position / state.zoom
			if e.button == .Right || .Control in e.modifiers {
				state.right_clicked_key = state.hot_key
				state.is_right_press = true
				continue
			}
			state.press_position = state.mouse
			state.active_key = state.hot_key
			state.pressed_key = state.hot_key
			state.click_count = e.click_count
		case platform.Mouse_Release:
			if state.is_right_press {
				state.is_right_press = false
				continue
			}
			if state.active_key != 0 && state.active_key == state.hot_key do state.clicked_key = state.active_key
			state.active_key = 0
		case platform.Mouse_Exit:
			state.mouse = {-1, -1}
		case platform.Scroll:
			delta := e.delta / state.zoom if e.is_precise else e.delta * POINTS_PER_LINE

			if e.is_start {
				state.swipe_axis = nil
				state.swipe_pending = {}
			}

			if e.is_precise {
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
				// A trackpad already moves smoothly, and macOS adds the glide after a flick.
				if e.is_precise do box.scroll = box.scroll_target
			}
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

is_animating :: proc() -> bool {
	return state.is_animating
}

to_key :: proc(id: string, seed: u64) -> u64 {
	return hash.fnv64a(transmute([]u8)id, seed * 0x100000001b3 + 0xcbf29ce484222325)
}

current_parent :: proc() -> ^Box {
	return state.parents[len(state.parents) - 1]
}

// A box keyed by id under the current parent, kept between frames. An empty id makes a box with no state.
box :: proc(id: string, style: Style, text: string = "") -> ^Box {
	parent := current_parent()
	key := to_key(id, parent.key) if id != "" else 0
	box := make_box(key, style)
	box.text = text
	box.parent = parent

	if parent.last == nil {
		parent.first = box
	} else {
		parent.last.next = box
	}
	parent.last = box

	return box
}

@(private)
make_box :: proc(key: u64, style: Style) -> ^Box {
	box: ^Box

	if key == 0 {
		box = new(Box, context.temp_allocator)
	} else {
		found, ok := state.boxes[key]
		if !ok {
			found = new(Box)
			found.key = key
			state.boxes[key] = found
		}
		box = found
	}

	box.style = style
	box.first = nil
	box.last = nil
	box.next = nil
	box.text = ""
	box.draw = nil
	box.color_of = nil
	box.data = nil
	box.last_built_frame = state.frame_index

	return box
}

// Makes the box the parent of the boxes built inside the if.
@(deferred_none = pop_parent)
scope :: proc(box: ^Box) -> bool {
	append(&state.parents, box)

	return true
}

pop_parent :: proc() {
	pop(&state.parents)
}

signal :: proc(box: ^Box) -> Signal {
	is_hovered := box.key != 0 && box.key == state.hot_key

	return Signal {
		box         = box,
		is_hovered  = is_hovered,
		is_held     = box.key != 0 && box.key == state.active_key,
		is_clicked  = box.key != 0 && box.key == state.clicked_key,
		is_right_clicked = box.key != 0 && box.key == state.right_clicked_key,
		click_count = state.click_count,
	}
}

find_box :: proc(id: string, parent: ^Box) -> ^Box {
	return state.boxes[to_key(id, parent.key)] or_else nil
}

set_scroll :: proc(box: ^Box, scroll: f32) {
	box.scroll = scroll
	box.scroll_target = scroll
}

// Moves toward target at rate per second and returns where it is now, kept under id between frames.
animate :: proc(id: string, target: f32, rate: f32 = HOT_RATE) -> f32 {
	key := to_key(id, 0)
	value, ok := state.values[key]

	if !ok do value.value = target

	value.value = approach(value.value, target, rate)
	value.last_built_frame = state.frame_index
	state.values[key] = value

	return value.value
}

@(private)
approach :: proc(value, target, rate: f32) -> f32 {
	next := value + (target - value) * (1 - math.exp(-state.dt_seconds * rate))

	if abs(target - next) < SETTLED * max(1, abs(target)) do return target

	state.is_animating = true

	return next
}

end_frame :: proc() {
	remove_unbuilt()
	measure(state.root)
	resolve(state.root)
	place(state.root, {0, 0}, {0, 0, state.root.size.x, state.root.size.y})
	find_hot()
	draw(state.root, {0, 0, 1e9, 1e9}, 1)
}

@(private)
remove_unbuilt :: proc() {
	for key, box in state.boxes {
		if box.last_built_frame == state.frame_index do continue

		free(box)
		delete_key(&state.boxes, key)
	}

	for key, value in state.values {
		if value.last_built_frame != state.frame_index do delete_key(&state.values, key)
	}
}

@(private)
to_font :: proc(style: Style) -> font.Font {
	size := style.font_size if style.font_size > 0 else 13

	return font.system_font(style.font_weight, size * state.scale)
}

// Sizes that need no parent, worked out from the leaves up.
@(private)
measure :: proc(box: ^Box) {
	for child := box.first; child != nil; child = child.next do measure(child)

	if box.text != "" do box.shaped = font.shape(box.text, to_font(box.style))

	box.size = {measure_axis(box, .X), measure_axis(box, .Y)}
}

@(private)
measure_axis :: proc(box: ^Box, axis: Axis) -> f32 {
	size := box.style.width if axis == .X else box.style.height
	padding := box.style.padding.x + box.style.padding.z if axis == .X else box.style.padding.y + box.style.padding.w

	#partial switch size.kind {
	case .Points:
		return size.value
	case .Text:
		if box.shaped == nil do return padding
		return math.ceil(box.shaped.size[int(axis)] / state.scale) + padding
	case .Children:
		return children_extent(box, axis) + padding
	}

	return 0
}

@(private)
children_extent :: proc(box: ^Box, axis: Axis) -> f32 {
	total: f32
	count := 0

	for child := box.first; child != nil; child = child.next {
		if .Floating in child.style.flags do continue

		count += 1
		if axis == box.style.axis {
			total += child.size[int(axis)]
		} else {
			total = max(total, child.size[int(axis)])
		}
	}

	if axis == box.style.axis && count > 1 do total += box.style.gap * f32(count - 1)

	return total
}

// Sizes that need the parent, from the root down. A box sized by its children grows to fit text that
// wrapped below it, before anything is placed, so a box aligned to the end or the centre is placed by
// its final size.
@(private)
resolve :: proc(box: ^Box) {
	style := box.style
	resolve_children(box, {box.size.x - style.padding.x - style.padding.z, box.size.y - style.padding.y - style.padding.w})

	for child := box.first; child != nil; child = child.next do resolve(child)

	if style.width.kind == .Children && style.axis == .Y do box.size.x = children_extent(box, .X) + style.padding.x + style.padding.z
	if style.height.kind == .Children {
		extent := wrap_lines(box, nil) if is_wrapping(box) else children_extent(box, .Y)
		box.size.y = extent + style.padding.y + style.padding.w
	}
}

@(private)
is_wrapping :: proc(box: ^Box) -> bool {
	return .Wrap_Children in box.style.flags && box.style.axis == .X
}

// Lays a wrapping row's children in lines no wider than the row, and returns the height of the lines.
// With a clip, it places them too.
@(private)
wrap_lines :: proc(box: ^Box, clip: ^[4]f32) -> f32 {
	style := box.style
	inner_width := box.size.x - style.padding.x - style.padding.z
	line_top: f32
	line := box.first

	for line != nil {
		// The children that fit on this line, and the tallest of them.
		width, height: f32
		end := line
		count := 0

		for child := line; child != nil; child = child.next {
			if .Floating in child.style.flags {
				end = child.next
				continue
			}

			next_width := width + child.size.x + (style.gap if count > 0 else 0)
			if count > 0 && next_width > inner_width do break

			width = next_width
			height = max(height, child.size.y)
			count += 1
			end = child.next
		}

		if clip != nil {
			pen := [2]f32{box.rect.x + style.padding.x, box.rect.y + style.padding.y + line_top}

			for child := line; child != end; child = child.next {
				if .Floating in child.style.flags {
					place(child, {box.rect.x, box.rect.y} + child.style.position, clip^)
					continue
				}

				origin := pen
				switch style.align {
				case .Start:
				case .Center:
					origin.y += math.round((height - child.size.y) / 2)
				case .End:
					origin.y += height - child.size.y
				}
				place(child, origin, clip^)
				pen.x += child.size.x + style.gap
			}
		}

		line_top += height
		line = end
		if line != nil do line_top += style.gap
	}

	return line_top
}

// Positions, from the root down. clip is in points.
@(private)
place :: proc(box: ^Box, origin: [2]f32, clip: [4]f32) {
	box.rect = {origin.x, origin.y, origin.x + box.size.x, origin.y + box.size.y}
	box.clip = clip

	style := box.style
	inner := [2]f32{box.size.x - style.padding.x - style.padding.z, box.size.y - style.padding.y - style.padding.w}
	main := int(style.axis)
	cross := 1 - main

	child_clip := intersect(clip, box.rect) if .Clip in style.flags else clip
	extent := children_extent(box, style.axis)
	box.content_size = {0, 0}
	box.content_size[main] = extent + style.padding[main] + style.padding[main + 2]

	if .Scroll in style.flags {
		max_scroll := max(0, box.content_size[main] - box.size[main])
		box.scroll_target = clamp(box.scroll_target, 0, max_scroll)
		box.scroll = clamp(approach(box.scroll, box.scroll_target, HOT_RATE), 0, max_scroll)
	}

	if is_wrapping(box) {
		wrap_lines(box, &child_clip)
		if .Animate_Position in style.flags do animate_rect(box)
		return
	}

	pen := [2]f32{box.rect.x + style.padding.x, box.rect.y + style.padding.y}
	if .Scroll in style.flags do pen[main] -= box.scroll

	for child := box.first; child != nil; child = child.next {
		if .Floating in child.style.flags {
			place(child, {box.rect.x, box.rect.y} + child.style.position, child_clip)
			continue
		}

		child_origin := pen
		free_space := inner[cross] - child.size[cross]
		switch style.align {
		case .Start:
		case .Center:
			child_origin[cross] += math.round(free_space / 2)
		case .End:
			child_origin[cross] += free_space
		}

		place(child, child_origin, child_clip)
		pen[main] += child.size[main] + style.gap
	}

	if .Animate_Position in style.flags do animate_rect(box)
}

@(private)
resolve_children :: proc(box: ^Box, inner: [2]f32) {
	main := int(box.style.axis)
	cross := 1 - main
	used: f32
	fill_weight: f32
	count := 0

	for child := box.first; child != nil; child = child.next {
		if .Floating in child.style.flags {
			resolve_free_size(child, inner)
			continue
		}

		sizes := [2]Size{child.style.width, child.style.height}
		count += 1

		if sizes[main].kind == .Percent do child.size[main] = inner[main] * sizes[main].value
		if sizes[cross].kind == .Percent do child.size[cross] = inner[cross] * sizes[cross].value
		if sizes[cross].kind == .Fill do child.size[cross] = inner[cross]

		if sizes[main].kind == .Fill {
			fill_weight += sizes[main].value
		} else {
			used += child.size[main]
		}
	}

	if count > 1 do used += box.style.gap * f32(count - 1)

	leftover := max(0, inner[main] - used)

	for child := box.first; child != nil; child = child.next {
		sizes := [2]Size{child.style.width, child.style.height}

		if .Floating not_in child.style.flags && sizes[main].kind == .Fill && fill_weight > 0 {
			child.size[main] = math.floor(leftover * sizes[main].value / fill_weight)
		}

		if .Wrap_Text in child.style.flags || .Truncate_Text in child.style.flags do fit_text_to_width(child)
	}
}

@(private)
resolve_free_size :: proc(child: ^Box, inner: [2]f32) {
	if child.style.width.kind == .Percent do child.size.x = inner.x * child.style.width.value
	if child.style.height.kind == .Percent do child.size.y = inner.y * child.style.height.value
	if child.style.width.kind == .Fill do child.size.x = inner.x
	if child.style.height.kind == .Fill do child.size.y = inner.y
}

// Wrapped text needs its width before its height is known.
@(private)
fit_text_to_width :: proc(box: ^Box) {
	if box.text == "" do return

	inner_width := box.size.x - box.style.padding.x - box.style.padding.z
	overflow := font.Overflow.Truncate if .Truncate_Text in box.style.flags else font.Overflow.Wrap
	box.shaped = font.shape(box.text, to_font(box.style), inner_width * state.scale, overflow)

	if box.style.height.kind == .Text {
		box.size.y = math.ceil(box.shaped.size.y / state.scale) + box.style.padding.y + box.style.padding.w
	}
}

@(private)
animate_rect :: proc(box: ^Box) {
	if !box.is_shown {
		box.shown_rect = box.rect
		box.is_shown = true
		return
	}

	for index in 0 ..< 4 do box.shown_rect[index] = approach(box.shown_rect[index], box.rect[index], HOT_RATE / 2)
}

@(private)
intersect :: proc(a, b: [4]f32) -> [4]f32 {
	return {max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w)}
}

@(private)
is_inside :: proc(point: [2]f32, rect: [4]f32) -> bool {
	return point.x >= rect.x && point.x < rect.z && point.y >= rect.y && point.y < rect.w
}

// The last box drawn under the mouse takes it, as it is drawn on top.
@(private)
find_hot :: proc() {
	state.hot_key = 0
	state.scroll_keys = {}
	visit_hot(state.root)

	for _, box in state.boxes {
		is_hot := box.key == state.hot_key && (state.active_key == 0 || state.active_key == box.key)
		box.hot_t = approach(box.hot_t, 1 if is_hot else 0, HOT_RATE)
		box.active_t = approach(box.active_t, 1 if box.key == state.active_key else 0, HOT_RATE)
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

@(private)
mix :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	if b.a == 0 do return a

	return a + (b - a) * t
}

@(private)
draw :: proc(box: ^Box, clip: [4]f32, parent_opacity: f32) {
	style := box.style
	opacity := parent_opacity * (1 - style.fade)

	if opacity <= 0 do return

	rect := box.shown_rect if .Animate_Position in style.flags && box.is_shown else box.rect
	scale := state.scale
	rect_pixels := rect * scale
	clip_pixels := clip * scale

	if rect.x > clip.z || rect.z < clip.x || rect.y > clip.w || rect.w < clip.y {
		if .Clip in style.flags do return
	}

	background := mix(mix(style.background, style.hover_background, box.hot_t), style.press_background, box.active_t)

	has_gradient := style.gradient.y > style.gradient.x

	if background.a > 0 || style.border_width > 0 || has_gradient {
		render.push({
			end_color     = {style.end_background.r, style.end_background.g, style.end_background.b, style.end_background.a * opacity},
			gradient      = style.gradient,
			rect          = rect_pixels,
			color         = {background.r, background.g, background.b, background.a * opacity},
			border_color  = {style.border_color.r, style.border_color.g, style.border_color.b, style.border_color.a * opacity},
			border_width  = style.border_width * scale,
			corner_radius = style.corner_radius * scale,
			softness      = style.softness * scale,
			clip          = clip_pixels,
		})
	}

	if box.shaped != nil do draw_text(box, rect, clip_pixels, opacity)
	if box.draw != nil do box.draw(box, rect_pixels, clip_pixels, opacity)

	child_clip := intersect(clip, rect) if .Clip in style.flags else clip

	for child := box.first; child != nil; child = child.next do draw(child, child_clip, opacity)
}

@(private)
draw_text :: proc(box: ^Box, rect: [4]f32, clip_pixels: [4]f32, opacity: f32) {
	style := box.style
	scale := state.scale
	inner := [4]f32{rect.x + style.padding.x, rect.y + style.padding.y, rect.z - style.padding.z, rect.w - style.padding.w}
	text_size := box.shaped.size / scale
	left := inner.x

	switch style.text_align {
	case .Start:
	case .Center:
		left += (inner.z - inner.x - text_size.x) / 2
	case .End:
		left = inner.z - text_size.x
	}

	left -= style.text_offset
	top := inner.y + (inner.w - inner.y - text_size.y) / 2
	origin := [2]f32{math.round(left * scale), math.round(top * scale)}
	font.draw(box.shaped, origin, style.text_color, intersect(clip_pixels, inner * scale), box.color_of, box.data, opacity)
}

to_pixels :: proc(points: f32) -> f32 {
	return points * state.scale
}
