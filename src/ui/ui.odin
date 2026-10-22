// An immediate mode UI after Ryan Fleury's. The app builds a tree of boxes every frame. A cache keyed
// by the ID of each box keeps its state from one frame to the next.
package ui

import "core:hash"
import "core:math"
import "om:font"

Axis :: enum {
	X,
	Y,
}

Size_Kind :: enum {
	Points,
	// The size of the text and the padding.
	Text,
	// A share of the parent, without its padding.
	Percent,
	// The children laid along the axis, or the largest one across it.
	Children,
	// The space that remains in the parent along its axis, shared by weight. Across it, the whole parent.
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
	// The box takes hover, press and click.
	Clickable,
	// The box takes hover only, such as a title that slides to show the rest.
	Hoverable,
	// The box scrolls its children along its axis.
	Scroll,
	// The box hides the children outside its rect.
	Clip,
	// The parent places the box at style.position, out of the flow.
	Floating,
	// The box glides to a new place instead of jumping.
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
	// The alignment of the children across the axis.
	align:            Align,
	text_align:       Align,
	// The text moves left by this many points, inside its clip.
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

// A Draw_Proc draws what a style cannot, such as an image. Its rects are in pixels.
Draw_Proc :: proc(box: ^Box, rect, clip: [4]f32, opacity: f32)

Box :: struct {
	key:              u64,
	parent:           ^Box,
	first, last:      ^Box,
	next:             ^Box,
	style:            Style,
	text:             string,
	draw:             Draw_Proc,
	// The proc colours the text per character instead of style.text_color.
	color_of:         font.Color_Proc,
	data:             rawptr,
	last_built_frame: int,
	// The layout sets these, in points from the top left of the window.
	size:             [2]f32,
	rect:             [4]f32,
	clip:             [4]f32,
	content_size:     [2]f32,
	shaped:           ^font.Shaped_Text,
	// The cache keeps these between frames.
	hot_fraction:     f32,
	active_fraction:  f32,
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
	click_count:      int,
}

@(private)
Animated_Value :: struct {
	value:            f32,
	last_built_frame: int,
}

// Hover and press fade in at this rate, per second.
HOT_RATE :: 20

// The points that a mouse wheel moves per line.
POINTS_PER_LINE :: 40

@(private)
SETTLED :: 0.002

@(private)
state: struct {
	boxes:             map[u64]^Box,
	values:            map[u64]Animated_Value,
	root:              ^Box,
	parents:           [dynamic]^Box,
	frame_index:       int,
	scale:             f32,
	zoom:              f32,
	frame_seconds:     f32,
	mouse:             [2]f32,
	hot_key:           u64,
	active_key:        u64,
	// The box under the mouse that scrolls along each axis.
	scroll_keys:       [Axis]u64,
	// A trackpad swipe and its glide move along one axis, the one its first points went most along.
	swipe_axis:        Maybe(Axis),
	// The points the swipe moves before it has an axis.
	swipe_pending:     [2]f32,
	clicked_key:       u64,
	right_clicked_key: u64,
	// The held button belongs to a right click, so its release clicks nothing.
	is_right_press:    bool,
	// Where the left button went down, for a drag.
	press_position:    [2]f32,
	pressed_key:       u64,
	click_count:       int,
	is_animating:      bool,
}

// Points are window points divided by zoom. scale turns points into pixels.
begin_frame :: proc(window_size_points: [2]f32, pixels_per_point, zoom, frame_seconds: f32) {
	state.frame_index += 1
	state.zoom = zoom
	state.scale = pixels_per_point * zoom
	state.frame_seconds = min(frame_seconds, 1.0 / 30)
	state.clicked_key = 0
	state.right_clicked_key = 0
	state.pressed_key = 0
	state.is_animating = false

	apply_events()

	clear(&state.parents)
	state.root = make_box(
		0,
		{
			width = points(window_size_points.x / zoom),
			height = points(window_size_points.y / zoom),
		},
	)
	append(&state.parents, state.root)
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
	box.shaped = nil
	box.draw = nil
	box.color_of = nil
	box.data = nil
	box.last_built_frame = state.frame_index

	return box
}

// Makes the box the parent of the boxes built inside the if. deferred_none calls pop_parent when that if ends.
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
		box = box,
		is_hovered = is_hovered,
		is_held = box.key != 0 && box.key == state.active_key,
		is_clicked = box.key != 0 && box.key == state.clicked_key,
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
	next := value + (target - value) * (1 - math.exp(-state.frame_seconds * rate))

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

to_pixels :: proc(points: f32) -> f32 {
	return points * state.scale
}
