package browse

import "core:encoding/json"
import "core:fmt"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/playback"
import "om:app/youtube_pages"
import "om:apple"
import "om:ui"

SHOWN_SEARCH_SONG_COUNT :: 6

TOP_RESULT_POINTS :: 180

build_search_page :: proc(term: string) {
	path := fmt.tprintf(
		"/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=12",
		apple.STOREFRONT,
		apple.to_query_text(term),
	)
	watched := apple.watch(path)
	data, needs_read := core.find_page_data(path, watched.version, watched.phase)

	if needs_read {
		allocator := core.page_allocator(data)
		answer: apple.Search_Answer
		_ = json.unmarshal_string(watched.body, &answer, allocator = allocator)

		data.songs = apple.to_catalog_songs(answer.results.songs.data, allocator)
		data.cards = apple.to_cards(answer.results.albums.data, allocator)
		data.artists = apple.to_cards(answer.results.artists.data, allocator)
	}

	page := kit.page_scroll("search")

	if ui.scope(page) {
		kit.page_heading(fmt.tprintf("Results for \"%s\"", term))

		if watched.phase != .Ready {
			kit.build_phase(watched.phase, "the results")
			return
		}

		width := kit.to_content_width(page)

		if len(data.songs) + len(data.cards) + len(data.artists) == 0 {
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
			data.artists,
			lists.to_tile_size(width, SIMILAR_ARTIST_POINTS, lists.CARD_GAP_POINTS),
			true,
		)
	}
}

@(private = "file")
build_search_top :: proc(data: ^core.Page_Data) {
	top := ui.box("top", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 20})

	if ui.scope(top) {
		if len(data.artists) > 0 {
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
				lists.build_shelf_title("Top Result", false)

				if lists.build_card_tile("top artist", data.artists[0], TOP_RESULT_POINTS, true) {
					lists.open_card(data.artists, 0)
				}
			}
		}

		songs := data.songs[:min(len(data.songs), SHOWN_SEARCH_SONG_COUNT)]
		list := ui.box(
			"songs",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 0},
		)

		if ui.scope(list) {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.text,
					font_size = kit.SHELF_TITLE_POINTS,
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
					playback.is_current_song(song),
				) {
					playback.play_songs(songs, index)
				}
			}
		}
	}
}
