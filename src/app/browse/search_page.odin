package browse

import "core:encoding/json"
import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/matching"
import "om:app/playback"
import "om:app/youtube_pages"
import "om:apple"
import "om:ui"

SHOWN_SEARCH_SONG_COUNT :: 6

build_search_page :: proc(term: string) {
	path := fmt.tprintf(
		"/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=12",
		apple.STOREFRONT,
		apple.to_query_text(term),
	)
	watched := apple.watch(path)
	data, is_stale := core.find_page_data(path, watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		Search_Answer :: struct {
			results: struct {
				songs:   apple.Related,
				albums:  apple.Related,
				artists: apple.Related,
			},
		}
		allocator := core.page_allocator(data)
		answer: Search_Answer
		_ = json.unmarshal_string(watched.body, &answer, allocator = allocator)

		songs := make([]core.Catalog_Song, len(answer.results.songs.data), allocator)
		for song, index in answer.results.songs.data do songs[index] = apple.to_catalog_song(song)
		data.songs = songs
		data.cards = apple.list_cards(answer.results.albums.data, allocator)
		data.similar = apple.list_cards(answer.results.artists.data, allocator)
	}

	page := kit.page_scroll("search")

	if ui.scope(page) {
		kit.page_heading(fmt.tprintf("Results for \"%s\"", term))

		if watched.phase != .Ready {
			kit.note(kit.to_phase_text(watched.phase))
			return
		}

		width := page.size.x - page.style.padding.x - page.style.padding.z

		// YouTube may have what Apple lacks.
		if len(data.songs) + len(data.cards) + len(data.similar) == 0 {
			kit.note(fmt.tprintf("Apple Music has nothing for \"%s\".", term))
			youtube_pages.build_youtube_search_results(term, nil, width)
			return
		}

		build_search_top(data)
		youtube_pages.build_youtube_search_results(term, data.songs, width)
		if width <= 0 do return

		lists.build_card_row(
			"albums",
			"Albums",
			data.cards,
			lists.to_tile_size(width, ARTIST_ALBUM_POINTS, lists.CARD_GAP_POINTS),
		)
		lists.build_card_row(
			"artists",
			"Artists",
			data.similar,
			lists.to_tile_size(width, SIMILAR_ARTIST_POINTS, lists.CARD_GAP_POINTS),
			true,
		)
	}
}

@(private = "file")
build_search_top :: proc(data: ^core.Page_Data) {
	top := ui.box("top", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 20})

	if ui.scope(top) {
		if len(data.similar) > 0 {
			result := ui.box(
				"top result",
				{
					width = ui.points(TOP_RESULT_POINTS),
					height = ui.fit_children(),
					axis = .Y,
					gap = 10,
				},
			)

			if ui.scope(result) {
				ui.box(
					"",
					{
						width = ui.fill(),
						height = ui.fit_text(),
						text_color = kit.colors.text,
						font_size = 17,
						font_weight = .Bold,
					},
					"Top Result",
				)

				if lists.build_card_tile("top artist", data.similar[0], TOP_RESULT_POINTS, true) {
					lists.open_card(data.similar, 0)
				}
			}
		}

		songs := data.songs[:min(len(data.songs), SHOWN_SEARCH_SONG_COUNT)]
		list := ui.box(
			"songs",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 0},
		)
		current, is_playing := playback.find_queue_song(core.app.now_playing.song.persistent_id)

		if ui.scope(list) {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.text,
					font_size = 17,
					font_weight = .Bold,
					padding = {0, 0, 0, 10},
				},
				"Songs",
			)

			for song, index in songs {
				subtitle := fmt.tprintf("%s · %s", song.artist_name, song.album_name)

				if lists.build_song_row(
					fmt.tprintf("%d %s", index, song.id),
					song,
					subtitle,
					is_playing && matching.is_same_queue_song(current, song),
				) {
					playback.play_songs(songs, index)
				}
			}
		}
	}
}
