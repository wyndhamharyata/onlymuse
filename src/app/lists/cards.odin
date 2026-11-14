package lists

import "core:fmt"
import "core:math"
import "om:app/core"
import "om:app/look"
import "om:app/playback"
import "om:apple"
import "thor:images"
import "thor:kit"
import "thor:ui"

SHELF_TILE_WIDTH :: 150

FIRST_SHELF_TILE_WIDTH :: 210

WIDE_TILE_WIDTH :: 240

YOUTUBE_SYMBOL :: "play.rectangle.fill"

CARD_GAP :: 14

to_tile_size :: proc(width, target_width, gap: f32) -> f32 {
	// The count comes from the width the content settles at, so while the panel moves the tiles scale smoothly instead of jumping between counts.
	settled_width := width + look.to_panel_travel_left()
	count := max(1, math.round((settled_width + gap) / (target_width + gap)))

	// Not floored to whole points: thor snaps edges to pixels, and a floor makes every tile in a row jump a point at once.
	return (width - gap * (count - 1)) / count
}

build_shelf :: proc(id: string, shelf: apple.Shelf, width, target_width: f32) {
	target := WIDE_TILE_WIDTH if shelf.is_wide else target_width

	build_card_row(
		id,
		shelf.title,
		shelf.cards,
		to_tile_size(width, target, CARD_GAP),
		is_wide = shelf.is_wide,
		is_youtube = shelf.is_youtube,
	)
}

build_card_row :: proc(
	id, title: string,
	cards: []apple.Card,
	tile_size: f32,
	is_round := false,
	is_wide := false,
	is_youtube := false,
) {
	if len(cards) == 0 do return

	shelf := ui.box(id, {width = ui.fill(), axis = .Y, gap = 10})

	if ui.scope(shelf) {
		if title != "" do build_shelf_title(title, is_youtube)

		art_height := tile_size * 9 / 16 if is_wide else tile_size
		style := ui.Style {
			width  = ui.fill(),
			height = ui.points(art_height + TILE_TEXT_HEIGHT),
			axis   = .X,
			gap    = CARD_GAP,
			flags  = {.Scroll, .Clip},
		}

		if first, last, ok := kit.list("row", len(cards), tile_size, style); ok {
			for index in first ..< last {
				if build_card_tile(
					fmt.tprintf("%d_%s", index, cards[index].id),
					cards[index],
					tile_size,
					is_round,
					is_wide,
				) {
					open_card(cards, index)
				}
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

build_shelf_title :: proc(title: string, is_youtube: bool) {
	row := ui.box(
		"title",
		{width = ui.fill(), axis = .X, align = .Center, gap = 7},
	)

	if ui.scope(row) {
		if is_youtube do kit.icon_box(YOUTUBE_SYMBOL, 15, look.colors.youtube)
		ui.box(
			"",
			{
				width = ui.fill(),
				text_color = kit.colors.base_content,
				font_size = look.SHELF_TITLE_SIZE,
				font_weight = .Bold,
				text_fit = .Truncate,
			},
			title,
		)
	}
}

build_card_tile :: proc(
	id: string,
	card: apple.Card,
	tile_size: f32,
	is_round := false,
	is_wide := false,
) -> bool {
	can_open := card.kind != .Other
	tile := ui.box(
		id,
		{
			width = ui.points(tile_size),
			axis = .Y,
			gap = 3,
			align = .Center if is_round else .Start,
		},
	)
	signal: ui.Signal
	if can_open {
		label := card.name if card.subtitle == "" else fmt.tprintf("%s, %s", card.name, card.subtitle)
		signal = kit.as_button(tile, label)
	}

	// The tile's parent is its shelf, so a card on two shelves fades separately on each.
	hover_id := fmt.tprintf("%s %s hover", tile.parent.id, id)
	hover := ui.animate(hover_id, 1 if signal.is_hovered else 0, kit.motion.fast)

	if ui.scope(tile) {
		radius: f32 = tile_size / 2 if is_round else 8
		size := [2]f32{tile_size, tile_size * 9 / 16 if is_wide else tile_size}
		artwork := look.artwork_rect_box(
			apple.to_artwork_url(card.artwork, images.to_texture_size_px(ui.to_px(tile_size))),
			card.name,
			size,
			radius,
			look.to_placeholder(card.artwork, card.name, card_symbols[card.kind]),
		)

		if ui.scope(artwork) {
			ui.box(
				"",
				{
					width = ui.points(size.x),
					height = ui.points(size.y),
					corner_radius = radius,
					bg = {1, 1, 1, 0.08 * hover},
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
				text_color = kit.colors.base_content,
				font_size = kit.SMALL_TEXT_SIZE,
				text_align = text_align,
				text_fit = .Truncate,
			},
			card.name,
		)

		if !is_round {
			ui.box(
				"",
				{
					width = ui.fill(),
					text_color = kit.with_opacity(kit.colors.base_content, 0.7),
					font_size = 12,
					text_fit = .Truncate,
				},
				card.subtitle,
			)
		}
	}

	return signal.is_activated
}

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
