// The cards, shelves, song rows and grids that more than one page shows.
package lists

import "core:fmt"
import "core:math"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:apple"
import "om:ui"

SHELF_TILE_POINTS :: 150

FIRST_SHELF_TILE_POINTS :: 210

// A video's tile, in 16:9.
WIDE_TILE_POINTS :: 240

YOUTUBE_SYMBOL :: "play.rectangle.fill"

CARD_GAP_POINTS :: 14

// A shelf builds this many cards past each of its edges, so a fast scroll finds them ready.
EXTRA_CARD_COUNT :: 2

// The tile size that fits a whole number of tiles across width, as close to target as it can.
to_tile_size :: proc(width, target, gap: f32) -> f32 {
	count := max(1, math.round((width + gap) / (target + gap)))

	return math.floor((width - gap * (count - 1)) / count)
}

// Builds a shelf from Apple or YouTube, with its videos in wide tiles. width is the width of the page.
build_shelf :: proc(id: string, shelf: apple.Shelf, width, target_points: f32) {
	target := WIDE_TILE_POINTS if shelf.is_wide else target_points

	build_card_row(
		id,
		shelf.title,
		shelf.cards,
		to_tile_size(width, target, CARD_GAP_POINTS),
		is_wide = shelf.is_wide,
		is_youtube = shelf.is_youtube,
	)
}

// Builds a shelf of whole tiles, but only the tiles in view. Empty boxes keep the width of the rest.
build_card_row :: proc(
	id, title: string,
	cards: []apple.Card,
	tile_points: f32,
	is_round := false,
	is_wide := false,
	is_youtube := false,
) {
	if len(cards) == 0 do return

	shelf := ui.box(id, {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 10})

	if ui.scope(shelf) {
		if title != "" do build_shelf_title(title, is_youtube)

		row := ui.box(
			"row",
			{
				width = ui.fill(),
				height = ui.fit_children(),
				axis = .X,
				gap = CARD_GAP_POINTS,
				flags = {.Scroll, .Clip},
			},
		)
		step := tile_points + CARD_GAP_POINTS
		first := max(0, int(row.scroll / step) - EXTRA_CARD_COUNT)
		last := min(len(cards) - 1, int((row.scroll + row.size.x) / step) + EXTRA_CARD_COUNT)

		if ui.scope(row) {
			if first > 0 {
				ui.box(
					"",
					{
						width = ui.points(f32(first) * step - CARD_GAP_POINTS),
						height = ui.points(1),
					},
				)
			}

			for index in first ..= last {
				if build_card_tile(
					fmt.tprintf("%d %s", index, cards[index].id),
					cards[index],
					tile_points,
					is_round,
					is_wide,
				) {
					open_card(cards, index)
				}
			}

			if last < len(cards) - 1 {
				ui.box(
					"",
					{
						width = ui.points(f32(len(cards) - 1 - last) * step - CARD_GAP_POINTS),
						height = ui.points(1),
					},
				)
			}
		}
	}
}

card_symbols := [apple.Card_Kind]string {
	.Other            = "music.note",
	.Album            = "square.stack",
	.Library_Album    = "square.stack",
	.Artist           = "music.mic",
	.Playlist         = "music.note.list",
	.Library_Playlist = "music.note.list",
	.Song             = "music.note",
	.YouTube_Playlist = "music.note.list",
	.YouTube_Artist   = "music.mic",
}

// The name of a YouTube shelf starts with YouTube's mark.
build_shelf_title :: proc(title: string, is_youtube: bool) {
	row := ui.box(
		"title",
		{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .Center, gap = 7},
	)

	if ui.scope(row) {
		if is_youtube do kit.icon_box("", YOUTUBE_SYMBOL, 15, kit.colors.youtube)
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = 17,
				font_weight = .Bold,
				flags = {.Truncate_Text},
			},
			title,
		)
	}
}

// Returns true when the person clicks the tile. A wide tile shows a video in 16:9.
build_card_tile :: proc(
	id: string,
	card: apple.Card,
	tile_points: f32,
	is_round := false,
	is_wide := false,
) -> bool {
	can_open := card.kind != .Other
	// odinfmt cannot read a set literal with an if after it inside another literal, so tile_flags stands apart.
	tile_flags: ui.Flags = {.Clickable} if can_open else {}
	tile := ui.box(
		id,
		{
			width = ui.points(tile_points),
			height = ui.fit_children(),
			axis = .Y,
			gap = 3,
			align = .Center if is_round else .Start,
			flags = tile_flags,
		},
	)

	if ui.scope(tile) {
		radius: f32 = tile_points / 2 if is_round else 8
		size := [2]f32{tile_points, tile_points * 9 / 16 if is_wide else tile_points}
		artwork := kit.artwork_rect_box(
			apple.to_artwork_url(card.artwork, kit.to_artwork_pixels(tile_points)),
			size,
			radius,
			kit.to_placeholder(card.artwork, card.name, card_symbols[card.kind]),
		)

		if ui.scope(artwork) {
			ui.box(
				"",
				{
					width = ui.points(size.x),
					height = ui.points(size.y),
					corner_radius = radius,
					background = {1, 1, 1, 0.08 * tile.hot_fraction},
					flags = {.Floating},
				},
			)
		}

		ui.box("", {width = ui.points(1), height = ui.points(4)})

		text_align := ui.Align.Center if is_round else .Start
		ui.box(
			"",
			{
				width = ui.fill(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = 12.5,
				text_align = text_align,
				flags = {.Truncate_Text},
			},
			card.name,
		)

		if !is_round {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.dim,
					font_size = 12,
					flags = {.Truncate_Text},
				},
				card.subtitle,
			)
		}
	}

	return ui.signal(tile).is_clicked
}

// A song card plays the shelf's songs from it. The others open their page.
open_card :: proc(cards: []apple.Card, index: int) {
	card := cards[index]

	switch card.kind {
	case .Album, .Library_Album:
		core.navigate({kind = .Album, id = card.id, title = card.name})
	case .Artist:
		core.navigate({kind = .Artist, id = card.id, title = card.name})
	case .Playlist:
		core.navigate({kind = .Catalog_Playlist, id = card.id, title = card.name})
	case .Library_Playlist:
		core.navigate({kind = .Playlist, id = card.id, title = card.name})
	case .YouTube_Playlist:
		kind :=
			core.Page_Kind.Bring_Over if core.current_page().kind == .Bring_Over else .YouTube_Playlist
		core.navigate({kind = kind, id = card.id, title = card.name})
	case .YouTube_Artist:
		// This opens the Apple Music artist of that name. The artist page then fills in from YouTube.
		core.navigate({kind = .Artist, title = card.name})
	case .Song:
		songs := make([dynamic]core.Catalog_Song, context.temp_allocator)
		first := 0

		for other, other_index in cards {
			if other.kind != .Song do continue
			if other_index == index do first = len(songs)
			append(&songs, other.song)
		}

		playback.play_songs(songs[:], first)
	case .Other:
	}
}
