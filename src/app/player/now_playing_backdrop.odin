package player

import "core:strings"
import "om:app/core"
import "om:apple"
import "om:image"
import "om:render"
import "om:ui"

BACKDROP_POINTS :: 520

// The backdrop draws the cover this small and stretches it, which blurs it with no blur.
BACKDROP_PIXELS :: 24

@(private = "file")
Backdrop_Paint :: struct {
	source: string,
}

@(private = "file")
draw_backdrop :: proc(box: ^ui.Box, rect, clip: [4]f32, opacity: f32) {
	paint := cast(^Backdrop_Paint)box.data
	texture, image_opacity := image.watch(paint.source, BACKDROP_PIXELS)
	if texture == nil do return

	// The square cover fills the wide box, so only its middle band shows.
	aspect := (rect.w - rect.y) / max(1, rect.z - rect.x)
	uv := [4]f32{0, 0.5 - aspect / 2, 1, 0.5 + aspect / 2}
	alpha := 0.6 * opacity * image_opacity

	render.push(
		{
			rect = rect,
			uv = uv,
			color = {0.62, 0.62, 0.62, alpha},
			gradient = {0.25, 1},
			clip = clip,
			kind = .Image,
		},
		texture,
	)
}

// The cover the page area spreads behind its toolbar and the page, as of the last frame that built Now Playing.
@(private = "file")
backdrop_source: string

@(private)
set_backdrop :: proc(artwork: apple.Artwork, artwork_path: string) {
	source := apple.to_artwork_url(artwork, BACKDROP_PIXELS)
	if source == "" do source = artwork_path
	if source == backdrop_source do return

	delete(backdrop_source)
	backdrop_source = strings.clone(source)
}

// The page area calls this before its toolbar, so the backdrop shows behind the toolbar too. It stays as the page scrolls.
build_page_backdrop :: proc() {
	if core.current_page().kind != .Now_Playing || backdrop_source == "" do return

	box := ui.box(
		"backdrop",
		{
			width = ui.fill(),
			height = ui.points(BACKDROP_POINTS),
			position = {0, 0},
			flags = {.Floating},
		},
	)

	paint := new(Backdrop_Paint, context.temp_allocator)
	paint.source = backdrop_source
	box.draw = draw_backdrop
	box.data = paint
}
