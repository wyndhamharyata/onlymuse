package ui

import "core:math"
import "om:font"
import "om:render"

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
