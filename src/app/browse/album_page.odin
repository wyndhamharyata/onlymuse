package browse

import "core:fmt"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/lists"
import "om:app/look"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "thor:kit"
import "thor:ui"

ALBUM_COVER_SIZE :: 240

ALBUM_HEADER_GAP :: 20

MIN_ALBUM_INFO_WIDTH :: 300

build_album_page :: proc(album_id: string) {
	catalog_id := album_id

	if strings.has_prefix(album_id, "l.") {
		link := apple.watch(fmt.tprintf("/v1/me/library/albums/%s/catalog", album_id))
		resources :=
			apple.to_resources(link.body, context.temp_allocator) if link.phase == .Ready else nil

		if len(resources) == 0 {
			page := look.page_scroll("album")

			if ui.scope(page) {
				if link.phase != .Ready {
					look.build_phase(link.phase, "the album")
				} else {
					kit.description("This album is only on the Mac, so Apple Music has no page for it.")
				}
			}

			return
		}

		catalog_id = resources[0].id
	}

	path := fmt.tprintf(
		"/v1/catalog/%s/albums/%s?include=artists&relate=library",
		apple.STOREFRONT,
		catalog_id,
	)
	watched := apple.watch(path)
	data, needs_read := core.find_page_data(path, watched.version, watched.phase)
	if needs_read do read_album(data, watched.body)

	page := look.page_scroll("album")
	if ui.scope(page) {
		if data.title == "" {
			look.build_phase(watched.phase, "the album")
			return
		}

		build_album_header(data, look.to_content_width(page))
		build_numbered_songs(data.songs)
	}
}

@(private = "file")
badge_labels := [][2]string {
	{"hi-res-lossless", "HI-RES LOSSLESS"},
	{"lossless", "LOSSLESS"},
	{"atmos", "DOLBY ATMOS"},
}

read_album :: proc(data: ^core.Page_Data, body: string) {
	allocator := core.page_allocator(data)
	resources := apple.to_resources(body, allocator)
	if len(resources) == 0 do return

	album := resources[0]
	attributes := album.attributes

	data.title = attributes.name
	data.subtitle = attributes.artist_name
	data.artwork = attributes.artwork

	artists := apple.read_related(album, "artists")
	if len(artists) > 0 do data.artist_id = artists[0].id
	data.is_in_library = len(apple.read_related(album, "library")) > 0

	data.songs = apple.to_catalog_songs(apple.read_related(album, "tracks"), allocator)

	genre := attributes.genre_names[0] if len(attributes.genre_names) > 0 else ""
	year := attributes.release_date[:min(4, len(attributes.release_date))]

	data.detail = fmt.aprintf(
		"%s · %s · %d songs",
		genre,
		year,
		len(data.songs),
		allocator = allocator,
	)

	badges := make([dynamic]string, allocator)

	for label in badge_labels {
		if slice.contains(attributes.audio_traits, label[0]) {
			append(&badges, label[1])
		}
	}

	data.badges = badges[:]
}

build_album_header :: proc(data: ^core.Page_Data, width: f32) {
	cover_size: f32 = ALBUM_COVER_SIZE if width <= 0 else min(ALBUM_COVER_SIZE, width)
	side := width - cover_size - ALBUM_HEADER_GAP
	is_side_by_side := width <= 0 || side >= MIN_ALBUM_INFO_WIDTH
	info := side if is_side_by_side && width > 0 else width

	header := ui.box(
		"header",
		{
			width = ui.fill(),
			axis = .X if is_side_by_side else .Y,
			align = .End if is_side_by_side else .Start,
			gap = ALBUM_HEADER_GAP,
		},
	)

	if ui.scope(header) {
		look.artwork_box(
			apple.to_artwork_url(data.artwork, look.to_artwork_px(cover_size)),
			cover_size,
			10,
			look.to_placeholder(data.artwork, data.title, "square.stack"),
		)
		build_album_info(data, info)
	}
}

@(private = "file")
MIN_LARGE_TITLE_INFO_WIDTH :: 360

@(private = "file")
MIN_MEDIUM_TITLE_INFO_WIDTH :: 240

@(private = "file")
build_album_info :: proc(data: ^core.Page_Data, info_width: f32) {
	title_size: f32 = 22

	if info_width <= 0 || info_width >= MIN_LARGE_TITLE_INFO_WIDTH {
		title_size = 32
	} else if info_width >= MIN_MEDIUM_TITLE_INFO_WIDTH {
		title_size = 26
	}

	library_label := "In Library" if data.is_in_library else "Not in Library"
	library_color := kit.to_color(0x7ee2a8ff) if data.is_in_library else kit.with_opacity(kit.colors.base_content, 0.5)

	info := ui.box("info", {width = ui.fill(), axis = .Y, gap = 6})

	if ui.scope(info) {
		ui.box(
			"",
			{
				width = ui.fill(),
				text_color = kit.colors.base_content,
				font_size = title_size,
				font_weight = .Bold,
				text_fit = .Wrap,
			},
			data.title,
		)

		artist := ui.box(
			"artist",
			{
				width = ui.fill(),
				text_color = kit.colors.primary,
				font_size = 20,
				font_weight = .Semibold,
				text_fit = .Truncate,
				pointer = .Click if data.artist_id != "" else .Passive,
			},
			data.subtitle,
		)

		if ui.signal(artist).is_activated {
			core.navigate({kind = .Artist, id = data.artist_id, title = data.subtitle})
		}

		kit.text(data.detail, kit.with_opacity(kit.colors.base_content, 0.7))

		badges := ui.box(
			"badges",
			{
				width = ui.fill(),
				axis = .X,
				gap = 8,
				padding = {0, 6, 0, 10},
				flags = {.Wrap_Children},
			},
		)

		if ui.scope(badges) {
			for label in data.badges do build_badge(label, kit.with_opacity(kit.colors.base_content, 0.7))
			build_badge(library_label, library_color)
		}

		buttons := ui.box(
			"buttons",
			{
				width = ui.fill(),
				axis = .X,
				gap = 8,
				flags = {.Wrap_Children},
			},
		)

		if ui.scope(buttons) do lists.build_play_buttons(data.songs)
	}
}

build_badge :: proc(label: string, color: [4]f32) {
	ui.box(
		"",
		{
			padding = {6, 1, 6, 1},
			corner_radius = 4,
			border_width = 1,
			border_color = color,
			text_color = color,
			font_size = 11,
			font_weight = .Bold,
		},
		label,
	)
}

build_numbered_songs :: proc(songs: []core.Catalog_Song) {
	tint := kit.with_opacity(kit.colors.primary, kit.SOFT_OPACITY)
	list := ui.box("songs", {width = ui.fill(), axis = .Y, gap = 1})

	if ui.scope(list) {
		for song, index in songs {
			is_current := playback.is_current_song(song)
			row := ui.box(
				fmt.tprintf("%d_%s", index, song.id),
				{
					width = ui.fill(),
					height = ui.points(36),
					axis = .X,
					align = .Center,
					gap = 12,
					padding = {10, 0, 10, 0},
					corner_radius = 7,
					bg = tint if is_current else {},
					hover_bg = tint if is_current else kit.with_opacity(kit.colors.base_content, kit.HOVER_OPACITY),
					pointer = .Click,
				},
			)

			if ui.scope(row) {
				ui.box(
					"",
					{
						width = ui.points(24),
						text_color = kit.colors.primary if is_current else kit.with_opacity(kit.colors.base_content, 0.5),
					},
					fmt.tprintf("%d", index + 1),
				)
				kit.text(song.name, kit.colors.primary if is_current else kit.colors.base_content)
				lists.build_row_heart(song, is_current)
				ui.box(
					"",
					{
						width = ui.points(44),
						text_align = .End,
						text_color = kit.with_opacity(kit.colors.base_content, 0.5),
						font_size = 12,
					},
					look.to_clock_text(song.duration_seconds),
				)
			}

			if menus.apply_song_row_signal(ui.signal(row), song) {
				playback.play_songs(songs, index)
			}
		}
	}
}
