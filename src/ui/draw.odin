package ui

import "core:math"
import "om:font"
import "om:render"

@(private)
mix :: proc(a, b: [4]f32, fraction: f32) -> [4]f32 {
	if b.a == 0 do return a

	return a + (b - a) * fraction
}

@(private)
draw :: proc(box: ^Box, clip: [4]f32, parent_opacity: f32) {
	style := box.style
	opacity := parent_opacity * (1 - style.fade)

	if opacity <= 0 do return

	rect := box.rect
	pixels_per_point := state.pixels_per_point
	rect_pixels := rect * pixels_per_point
	clip_pixels := clip * pixels_per_point
	is_outside := rect.x > clip.z || rect.z < clip.x || rect.y > clip.w || rect.w < clip.y

	if is_outside && .Clip in style.flags do return

	background := mix(
		mix(style.background, style.hover_background, box.hot_fraction),
		style.press_background,
		box.active_fraction,
	)

	has_gradient := style.gradient.y > style.gradient.x
	has_fill := background.a > 0 || style.border_width > 0 || has_gradient

	if has_fill {
		render.push(
			{
				end_color = to_faded_color(style.end_background, opacity),
				gradient = style.gradient,
				rect = rect_pixels,
				color = to_faded_color(background, opacity),
				border_color = to_faded_color(style.border_color, opacity),
				border_width = style.border_width * pixels_per_point,
				corner_radius = style.corner_radius * pixels_per_point,
				softness = style.softness * pixels_per_point,
				clip = clip_pixels,
			},
		)
	}

	if box.shaped != nil do draw_text(box, rect, clip_pixels, opacity)
	if box.draw != nil do box.draw(box, rect_pixels, clip_pixels, opacity)

	child_clip := intersect(clip, rect) if .Clip in style.flags else clip

	for child := box.first; child != nil; child = child.next do draw(child, child_clip, opacity)
}

@(private)
to_faded_color :: proc(color: [4]f32, opacity: f32) -> [4]f32 {
	return {color.r, color.g, color.b, color.a * opacity}
}

@(private)
draw_text :: proc(box: ^Box, rect: [4]f32, clip_pixels: [4]f32, opacity: f32) {
	style := box.style
	pixels_per_point := state.pixels_per_point
	inner := [4]f32 {
		rect.x + style.padding.x,
		rect.y + style.padding.y,
		rect.z - style.padding.z,
		rect.w - style.padding.w,
	}
	text_size := box.shaped.size_pixels / pixels_per_point
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
	origin := [2]f32{math.round(left * pixels_per_point), math.round(top * pixels_per_point)}

	font.draw(
		box.shaped,
		origin,
		style.text_color,
		intersect(clip_pixels, inner * pixels_per_point),
		box.color_of,
		box.data,
		opacity,
	)
}
