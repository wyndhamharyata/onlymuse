package browse

import "core:fmt"
import "core:slice"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/matching"
import "om:app/menus"
import "om:app/playback"
import "om:apple"
import "om:ui"

ALBUM_COVER_POINTS :: 240

ALBUM_HEADER_GAP_POINTS :: 20

MIN_ALBUM_INFO_POINTS :: 300

// Album IDs from the library start with "l.". Apple gives their catalog album first.
build_album_page :: proc(album_id: string) {
	catalog_id := album_id

	if len(album_id) > 2 && album_id[:2] == "l." {
		link := apple.watch(fmt.tprintf("/v1/me/library/albums/%s/catalog", album_id))
		resources :=
			apple.to_resources(link.body, context.temp_allocator) if link.phase == .Ready else nil

		if len(resources) == 0 {
			page := kit.page_scroll("album")
			if ui.scope(page) {
				kit.note(
					kit.phase_note(link.phase) if link.phase != .Ready else "This album is only on the Mac, so Apple Music has no page for it.",
				)
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
	data, is_stale := core.find_page_data(path, watched.version, watched.phase)
	if is_stale && watched.phase == .Ready do read_album(data, watched.body)

	page := kit.page_scroll("album")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		if watched.phase != .Ready || data.title == "" {
			kit.note(kit.phase_note(watched.phase))
			return
		}

		build_album_header(data, page.size.x - page.style.padding.x - page.style.padding.z)
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
	artists := apple.list_related(album, "artists")
	if len(artists) > 0 do data.link_id = artists[0].id
	data.is_in_library = len(apple.list_related(album, "library")) > 0

	tracks := apple.list_related(album, "tracks")
	songs := make([]core.Catalog_Song, len(tracks), allocator)
	for track, index in tracks do songs[index] = apple.to_catalog_song(track)
	data.songs = songs

	genre := attributes.genre_names[0] if len(attributes.genre_names) > 0 else ""
	year := attributes.release_date[:min(4, len(attributes.release_date))]
	data.detail = fmt.aprintf(
		"%s · %s · %d songs",
		genre,
		year,
		len(songs),
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

// width is the page's from the last frame, 0 on the first.
build_album_header :: proc(data: ^core.Page_Data, width: f32) {
	cover_points: f32 = ALBUM_COVER_POINTS if width <= 0 else min(ALBUM_COVER_POINTS, width)
	// The text goes under the cover when beside it, it would have too little room.
	is_side_by_side :=
		width <= 0 || width - cover_points - ALBUM_HEADER_GAP_POINTS >= MIN_ALBUM_INFO_POINTS
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

		info := ui.box("info", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 6})

		if ui.scope(info) {
			info_width :=
				width - cover_points - ALBUM_HEADER_GAP_POINTS if is_side_by_side && width > 0 else width
			title_size: f32 =
				32 if width <= 0 || info_width >= 360 else 26 if info_width >= 240 else 22
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

			artist_flags := ui.Flags{.Truncate_Text}
			if data.link_id != "" do artist_flags |= {.Clickable}
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
				core.navigate({kind = .Artist, id = data.link_id, title = data.subtitle})
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
				build_badge(
					"In Library" if data.is_in_library else "Not in Library",
					kit.to_color(0x7ee2a8ff) if data.is_in_library else kit.colors.faint,
				)
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

			if ui.scope(buttons) {
				if kit.action_button("Play", "play.fill", true) {
					playback.play_songs(data.songs, 0)
				}
				if kit.action_button("Shuffle", "shuffle", false) {
					playback.shuffle_songs(data.songs)
				}
			}
		}
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

// An album's songs, numbered. A click plays them from that song.
build_numbered_songs :: proc(songs: []core.Catalog_Song) {
	list := ui.box("songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 1})
	current, is_playing := playback.find_queue_song(core.app.now_playing.song.persistent_id)

	if ui.scope(list) {
		for song, index in songs {
			is_current := is_playing && matching.is_same_queue_song(current, song)
			tint := kit.to_accent_tint(core.app.accent)
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
				lists.build_row_heart(row, song, is_current)
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

			if menus.track_song_row(ui.signal(row), song) do playback.play_songs(songs, index)
		}
	}
}
