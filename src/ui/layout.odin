package ui

import "core:math"
import "om:font"

@(private)
to_font :: proc(style: Style) -> font.Font {
	size := style.font_size if style.font_size > 0 else 13

	return font.system_font(style.font_weight, size * state.scale)
}

// Works out the sizes that need no parent, from the bottom of the tree up.
@(private)
measure :: proc(box: ^Box) {
	for child := box.first; child != nil; child = child.next do measure(child)

	if box.text != "" do box.shaped = font.shape(box.text, to_font(box.style))

	box.size = {measure_axis(box, .X), measure_axis(box, .Y)}
}

@(private)
measure_axis :: proc(box: ^Box, axis: Axis) -> f32 {
	size := box.style.width if axis == .X else box.style.height
	padding :=
		box.style.padding.x + box.style.padding.z if axis == .X else box.style.padding.y + box.style.padding.w

	// resolve_children sizes Percent and Fill later.
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

// Works out the sizes that need the parent, from the root down. A box sized by its children then
// grows to fit the text that wrapped below it. place then aligns the box by this final size.
@(private)
resolve :: proc(box: ^Box) {
	style := box.style

	resolve_children(
		box,
		{
			box.size.x - style.padding.x - style.padding.z,
			box.size.y - style.padding.y - style.padding.w,
		},
	)

	for child := box.first; child != nil; child = child.next do resolve(child)

	if style.width.kind == .Children && style.axis == .Y {
		box.size.x = children_extent(box, .X) + style.padding.x + style.padding.z
	}

	if style.height.kind == .Children {
		extent := wrap_lines(box, nil) if is_wrapping(box) else children_extent(box, .Y)
		box.size.y = extent + style.padding.y + style.padding.w
	}
}

@(private)
is_wrapping :: proc(box: ^Box) -> bool {
	return .Wrap_Children in box.style.flags && box.style.axis == .X
}

// Lays a wrapping row's children in lines no wider than the row. It returns the lines' height.
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

// Places each box, from the root down. clip is in points.
@(private)
place :: proc(box: ^Box, origin: [2]f32, clip: [4]f32) {
	box.rect = {origin.x, origin.y, origin.x + box.size.x, origin.y + box.size.y}
	box.clip = clip

	style := box.style
	inner := [2]f32 {
		box.size.x - style.padding.x - style.padding.z,
		box.size.y - style.padding.y - style.padding.w,
	}
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

		if .Wrap_Text in child.style.flags || .Truncate_Text in child.style.flags {
			fit_text_to_width(child)
		}
	}
}

@(private)
resolve_free_size :: proc(child: ^Box, inner: [2]f32) {
	if child.style.width.kind == .Percent do child.size.x = inner.x * child.style.width.value
	if child.style.height.kind == .Percent do child.size.y = inner.y * child.style.height.value
	if child.style.width.kind == .Fill do child.size.x = inner.x
	if child.style.height.kind == .Fill do child.size.y = inner.y
}

// The height of wrapped text depends on its width.
@(private)
fit_text_to_width :: proc(box: ^Box) {
	if box.text == "" do return

	inner_width := box.size.x - box.style.padding.x - box.style.padding.z
	overflow := font.Overflow.Truncate if .Truncate_Text in box.style.flags else font.Overflow.Wrap

	box.shaped = font.shape(box.text, to_font(box.style), inner_width * state.scale, overflow)

	if box.style.height.kind == .Text {
		box.size.y =
			math.ceil(box.shaped.size.y / state.scale) + box.style.padding.y + box.style.padding.w
	}
}

@(private)
animate_rect :: proc(box: ^Box) {
	if !box.is_shown {
		box.shown_rect = box.rect
		box.is_shown = true
		return
	}

	for index in 0 ..< 4 {
		box.shown_rect[index] = approach(box.shown_rect[index], box.rect[index], HOT_RATE / 2)
	}
}

@(private)
intersect :: proc(a, b: [4]f32) -> [4]f32 {
	return {max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w)}
}
