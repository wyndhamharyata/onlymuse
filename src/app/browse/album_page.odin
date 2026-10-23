package browse

import "core:fmt"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "om:ui"

ALBUM_COVER_POINTS :: 240

ALBUM_HEADER_GAP_POINTS :: 20

MIN_ALBUM_INFO_POINTS :: 300

build_album_page :: proc(album_id: string) {
	catalog_id := album_id

	if strings.has_prefix(album_id, "l.") {
		link := apple.watch(fmt.tprintf("/v1/me/library/albums/%s/catalog", album_id))
		resources :=
			apple.to_resources(link.body, context.temp_allocator) if link.phase == .Ready else nil

		if len(resources) == 0 {
			page := kit.page_scroll("album")

			if ui.scope(page) {
				if link.phase != .Ready {
					kit.build_phase(link.phase, "the album")
				} else {
					kit.note("This album is only on the Mac, so Apple Music has no page for it.")
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

	page := kit.page_scroll("album")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		if data.title == "" {
			kit.build_phase(watched.phase, "the album")
			return
		}

		build_album_header(data, kit.to_content_width(page))
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
	cover_points: f32 = ALBUM_COVER_POINTS if width <= 0 else min(ALBUM_COVER_POINTS, width)
	side_points := width - cover_points - ALBUM_HEADER_GAP_POINTS
	is_side_by_side := width <= 0 || side_points >= MIN_ALBUM_INFO_POINTS
	info_points := side_points if is_side_by_side && width > 0 else width

	header := ui.box(
		"header",
		{
			width = ui.fill(),
			height = ui.fit_children(),
			axis = .X if is_side_by_side else .Y,
			align = .End if is_side_by_side else .Start,
			gap = ALBUM_HEADER_GAP_POINTS,
		},
	)

	if ui.scope(header) {
		kit.artwork_box(
			apple.to_artwork_url(data.artwork, kit.to_artwork_pixels(cover_points)),
			cover_points,
			10,
			kit.to_placeholder(data.artwork, data.title, "square.stack"),
		)
		build_album_info(data, info_points)
	}
}

@(private = "file")
MIN_LARGE_TITLE_INFO_POINTS :: 360

@(private = "file")
MIN_MEDIUM_TITLE_INFO_POINTS :: 240

@(private = "file")
build_album_info :: proc(data: ^core.Page_Data, info_points: f32) {
	title_size: f32 = 22

	if info_points <= 0 || info_points >= MIN_LARGE_TITLE_INFO_POINTS {
		title_size = 32
	} else if info_points >= MIN_MEDIUM_TITLE_INFO_POINTS {
		title_size = 26
	}

	artist_flags := ui.Flags{.Truncate_Text}
	if data.artist_id != "" do artist_flags |= {.Clickable}
	library_label := "In Library" if data.is_in_library else "Not in Library"
	library_color := kit.to_color(0x7ee2a8ff) if data.is_in_library else kit.colors.faint

	info := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 6})

	if ui.scope(info) {
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = title_size,
				font_weight = .Bold,
				flags = {.Wrap_Text},
			},
			data.title,
		)

		artist := ui.box(
			"artist",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = core.app.accent,
				font_size = 20,
				font_weight = .Semibold,
				flags = artist_flags,
			},
			data.subtitle,
		)

		if ui.signal(artist).is_clicked {
			core.navigate({kind = .Artist, id = data.artist_id, title = data.subtitle})
		}

		kit.text_box(data.detail, kit.colors.dim)

		badges := ui.box(
			"badges",
			{
				width = ui.fill(),
				height = ui.fit_children(),
				axis = .X,
				gap = 8,
				padding = {0, 6, 0, 10},
				flags = {.Wrap_Children},
			},
		)

		if ui.scope(badges) {
			for label in data.badges do build_badge(label, kit.colors.dim)
			build_badge(library_label, library_color)
		}

		buttons := ui.box(
			"buttons",
			{
				width = ui.fill(),
				height = ui.fit_children(),
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
			width = ui.fit_text(),
			height = ui.fit_text(),
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
	tint := kit.to_accent_tint(core.app.accent)
	list := ui.box("songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 1})

	if ui.scope(list) {
		for song, index in songs {
			is_current := playback.is_current_song(song)
			row := ui.box(
				fmt.tprintf("%d %s", index, song.id),
				{
					width = ui.fill(),
					height = ui.points(36),
					axis = .X,
					align = .Center,
					gap = 12,
					padding = {10, 0, 10, 0},
					corner_radius = 7,
					background = tint if is_current else {},
					hover_background = tint if is_current else kit.colors.hover,
					flags = {.Clickable},
				},
			)

			if ui.scope(row) {
				ui.box(
					"",
					{
						width = ui.points(24),
						height = ui.fit_text(),
						text_color = core.app.accent if is_current else kit.colors.faint,
					},
					fmt.tprintf("%d", index + 1),
				)
				kit.text_box(song.name, core.app.accent if is_current else kit.colors.text)
				lists.build_row_heart(song, is_current)
				ui.box(
					"",
					{
						width = ui.points(44),
						height = ui.fit_text(),
						text_align = .End,
						text_color = kit.colors.faint,
						font_size = 12,
					},
					kit.to_clock_text(song.duration_seconds),
				)
			}

			if menus.apply_song_row_signal(ui.signal(row), song) {
				playback.play_songs(songs, index)
			}
		}
	}
}
