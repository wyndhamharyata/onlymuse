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
	Text,
	Children,
	Fill,
}

Size :: struct {
	kind:  Size_Kind,
	value: f32,
}

points :: proc "contextless" (value: f32) -> Size {return {.Points, value}}

fill :: proc "contextless" (weight: f32 = 1) -> Size {return {.Fill, weight}}

fit_children :: proc "contextless" () -> Size {return {.Children, 0}}

fit_text :: proc "contextless" () -> Size {return {.Text, 0}}

Align :: enum {
	Start,
	Center,
	End,
}

Flag :: enum {
	Clickable,
	Hoverable,
	Scroll,
	Clip,
	Floating,
	Wrap_Text,
	Truncate_Text,
	Wrap_Children,
}

Flags :: bit_set[Flag]

Style :: struct {
	width, height:    Size,
	axis:             Axis,
	padding:          [4]f32,
	gap:              f32,
	align:            Align,
	text_align:       Align,
	text_offset:      f32,
	background:       [4]f32,
	softness:         f32,
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
	fade:             f32,
	position:         [2]f32,
	flags:            Flags,
}

Draw_Proc :: proc(box: ^Box, rect_pixels, clip_pixels: [4]f32, opacity: f32)

Box :: struct {
	key:              u64,
	parent:           ^Box,
	first, last:      ^Box,
	next:             ^Box,
	style:            Style,
	text:             string,
	draw:             Draw_Proc,
	color_of:         font.Color_Proc,
	data:             rawptr,
	last_built_frame: int,
	size:             [2]f32,
	rect:             [4]f32,
	clip:             [4]f32,
	content_size:     [2]f32,
	shaped:           ^font.Shaped_Text,
	hot_fraction:     f32,
	active_fraction:  f32,
	scroll:           f32,
	scroll_target:    f32,
}

@(private)
Animated_Value :: struct {
	value:            f32,
	last_built_frame: int,
}

HOT_RATE_PER_SECOND :: 20

POINTS_PER_LINE :: 40

@(private)
SETTLED_FRACTION :: 0.002

@(private)
MAX_FRAME_SECONDS :: 1.0 / 30

@(private)
NO_CLIP :: [4]f32{0, 0, 1e9, 1e9}

@(private)
state: struct {
	boxes:                  map[u64]^Box,
	values:                 map[u64]Animated_Value,
	root:                   ^Box,
	parents:                [dynamic]^Box,
	frame_index:            int,
	pixels_per_point:       f32,
	zoom:                   f32,
	frame_seconds:          f32,
	mouse:                  [2]f32,
	hot_key:                u64,
	active_key:             u64,
	scroll_keys:            [Axis]u64,
	swipe_axis:             Maybe(Axis),
	undecided_swipe_points: [2]f32,
	clicked_key:            u64,
	right_clicked_key:      u64,
	is_right_press:         bool,
	press_position:         [2]f32,
	pressed_key:            u64,
	is_animating:           bool,
}

begin_frame :: proc(window_size_points: [2]f32, pixels_per_point, zoom, frame_seconds: f32) {
	state.frame_index += 1
	state.zoom = zoom
	state.pixels_per_point = pixels_per_point * zoom
	state.frame_seconds = min(frame_seconds, MAX_FRAME_SECONDS)
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
	// 0x100000001b3 is the FNV-1a 64-bit prime. 0xcbf29ce484222325 is its offset basis.
	return hash.fnv64a(transmute([]u8)id, seed * 0x100000001b3 + 0xcbf29ce484222325)
}

current_parent :: proc() -> ^Box {
	return state.parents[len(state.parents) - 1]
}

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
	box, is_cached := state.boxes[key]

	if key == 0 {
		box = new(Box, context.temp_allocator)
	} else if !is_cached {
		box = new(Box)
		box.key = key
		state.boxes[key] = box
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

@(deferred_none = pop_parent)
scope :: proc(box: ^Box) -> bool {
	append(&state.parents, box)
	return true
}

pop_parent :: proc() {
	pop(&state.parents)
}

find_box :: proc(id: string, parent: ^Box) -> ^Box {
	return state.boxes[to_key(id, parent.key)] or_else nil
}

set_scroll :: proc(box: ^Box, scroll: f32) {
	box.scroll = scroll
	box.scroll_target = scroll
}

animate :: proc(id: string, target: f32, rate: f32 = HOT_RATE_PER_SECOND) -> f32 {
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

	if abs(target - next) < SETTLED_FRACTION * max(1, abs(target)) do return target

	state.is_animating = true

	return next
}

end_frame :: proc() {
	remove_unbuilt()
	measure(state.root)
	resolve(state.root)
	place(state.root, {0, 0}, {0, 0, state.root.size.x, state.root.size.y})
	apply_mouse_to_boxes()
	draw(state.root, NO_CLIP, 1)
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
	return points * state.pixels_per_point
}
