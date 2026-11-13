package browse

import "core:math"
import "om:app/core"
import "om:app/lists"
import "om:app/look"
import "om:apple"
import "thor:kit"
import "thor:ui"

PHOTO_WIDTH_STEP_PIXELS :: 400

LATEST_RELEASE_POINTS :: 210

ARTIST_HEADER_RADIUS_POINTS :: 12

ARTIST_SHADE_ALPHA :: 0xf2 / 255.0

@(private)
build_artist_header :: proc(data: ^core.Page_Data, detail: string, width: f32) {
	fallback_color :=
		kit.to_color_from_hex(data.artwork.background_color) or_else kit.colors.base_300
	header := ui.box("header", {width = ui.fill(), height = ui.points(ARTIST_HEADER_POINTS)})

	if ui.scope(header) {
		if width > 0 {
			photo_width :=
				int(math.ceil(ui.to_pixels(width) / PHOTO_WIDTH_STEP_PIXELS)) *
				PHOTO_WIDTH_STEP_PIXELS
			// Apple fits the photo inside the asked size. A square gives the whole photo to crop.
			photo := apple.to_artwork_url(data.artwork, photo_width)
			box := look.artwork_rect_box(
				photo,
				{width, ARTIST_HEADER_POINTS},
				ARTIST_HEADER_RADIUS_POINTS,
				{top = fallback_color, bottom = fallback_color},
			)
			box.style.flags += {.Floating}
			if box.data != nil do (cast(^look.Artwork_Paint)box.data).focus_y = 0.25
		}

		window_color := kit.colors.base_100
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fill(),
				corner_radius = ARTIST_HEADER_RADIUS_POINTS,
				layers = {
					ui.Gradient {
						from = {window_color.r, window_color.g, window_color.b, 0},
						to = {window_color.r, window_color.g, window_color.b, ARTIST_SHADE_ALPHA},
						stops = {0.35, 1},
					},
				},
				flags = {.Floating},
			},
		)

		bottom := ui.box(
			"bottom",
			{
				width = ui.fill(),
				height = ui.fill(),
				axis = .X,
				align = .End,
				gap = 10,
				padding = {20, 0, 20, 18},
				flags = {.Floating},
			},
		)

		if ui.scope(bottom) {
			name := ui.box("name", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(name) {
				ui.box(
					"",
					{
						width = ui.fill(),
						height = ui.fit_text(),
						text_color = kit.colors.base_content,
						font_size = 40,
						font_weight = .Bold,
						text_fit = .Truncate,
					},
					data.title,
				)
				kit.text(detail, kit.to_color(0xcfcfd4ff), 14)
			}

			lists.build_play_buttons(data.songs)
		}
	}
}

@(private)
build_artist_middle :: proc(data: ^core.Page_Data) {
	middle := ui.box(
		"middle",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 20},
	)

	if ui.scope(middle) {
		if len(data.latest) > 0 {
			latest := ui.box(
				"latest",
				{
					width = ui.points(LATEST_RELEASE_POINTS),
					height = ui.fit_children(),
					axis = .Y,
					gap = 10,
				},
			)

			if ui.scope(latest) {
				lists.build_shelf_title("Latest Release", false)

				if lists.build_card_tile("latest card", data.latest[0], LATEST_RELEASE_POINTS) {
					lists.open_card(data.latest, 0)
				}
			}
		}

		top := ui.box(
			"top_songs",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10},
		)

		if ui.scope(top) {
			lists.build_shelf_title("Top Songs", false)

			lists.build_song_grid(data.songs, nil, data.songs)
		}
	}
}
