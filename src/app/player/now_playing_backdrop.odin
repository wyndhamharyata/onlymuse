package player

import "core:strings"
import "om:app/core"
import "om:apple"
import "om:image"
import "om:render"
import "om:ui"

BACKDROP_HEIGHT_POINTS :: 520

// The backdrop stretches a cover this small, which blurs it without a blur shader.
BACKDROP_PIXELS :: 24

BACKDROP_OPACITY :: 0.6

BACKDROP_BRIGHTNESS :: 0.62

@(private = "file")
Backdrop_Paint :: struct {
	source: string,
}

@(private = "file")
draw_backdrop :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Backdrop_Paint)box.data
	texture, image_opacity := image.watch(paint.source, BACKDROP_PIXELS)
	if texture == nil do return

	aspect := (rect.w - rect.y) / max(1, rect.z - rect.x)
	uv := [4]f32{0, 0.5 - aspect / 2, 1, 0.5 + aspect / 2}
	alpha := BACKDROP_OPACITY * opacity * image_opacity

	render.push(
		{
			rect = rect,
			uv = uv,
			color = {BACKDROP_BRIGHTNESS, BACKDROP_BRIGHTNESS, BACKDROP_BRIGHTNESS, alpha},
			gradient = {0.25, 1},
			clip = clip,
			kind = .Image,
		},
		texture,
	)
}

@(private = "file")
backdrop_source: string

@(private)
to_cover_source :: proc(artwork: apple.Artwork, size_pixels: int, artwork_path: string) -> string {
	url := apple.to_artwork_url(artwork, size_pixels)

	return url if url != "" else artwork_path
}

@(private)
set_backdrop :: proc(artwork: apple.Artwork, artwork_path: string) {
	source := to_cover_source(artwork, BACKDROP_PIXELS, artwork_path)
	if source == backdrop_source do return

	delete(backdrop_source)
	backdrop_source = strings.clone(source)
}

build_page_backdrop :: proc() {
	is_shown := core.current_page().kind == .Now_Playing && backdrop_source != ""
	if !is_shown do return

	box := ui.box(
		"backdrop",
		{
			width = ui.fill(),
			height = ui.points(BACKDROP_HEIGHT_POINTS),
			position = {0, 0},
			flags = {.Floating},
		},
	)

	paint := new(Backdrop_Paint, context.temp_allocator)
	paint.source = backdrop_source
	box.draw = draw_backdrop
	box.data = paint
}
