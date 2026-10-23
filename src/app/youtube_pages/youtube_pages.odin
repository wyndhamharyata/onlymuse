package youtube_pages

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/matching"
import "om:app/playback"
import "om:app/youtube_lists"
import "om:apple"
import "om:helper"
import "om:ui"
import "om:youtube"

SHOWN_YOUTUBE_SONG_COUNT :: 6

build_youtube_playlist_page :: proc(page: core.Page) {
	if page.id == youtube.LIKED_ID && !youtube.is_signed_in() {
		build_youtube_sign_in_page(
			"Liked Music",
			"Sign in to YouTube Music to see the songs you liked there.",
		)
		return
	}

	first, songs, phase := youtube_lists.watch_youtube_songs(youtube.to_list_path(page.id))
	title := first.title if first.title != "" else page.title

	lists.build_song_list_page(title, first.subtitle, songs, phase)
}

// YouTube's mixes for you show on its home page as playlists with IDs that start "RD" or "VLRD".
build_youtube_mixes_page :: proc() {
	if !youtube.is_signed_in() {
		build_youtube_sign_in_page(
			"Mixes",
			"Sign in to YouTube Music to see the mixes it made for you.",
		)
		return
	}

	shelves, signature, phase := youtube_lists.watch_youtube_home()
	data, needs_read := core.find_page_data("youtube mixes", signature, phase)

	if needs_read {
		cards := make([dynamic]apple.Card, core.page_allocator(data))
		seen := make(map[string]bool, context.temp_allocator)

		for shelf in shelves {
			for card in shelf.cards {
				is_mix :=
					card.kind == .YouTube_Playlist &&
					(strings.has_prefix(card.id, "RD") || strings.has_prefix(card.id, "VLRD"))
				if !is_mix || seen[card.id] do continue

				seen[card.id] = true
				append(&cards, core.copy_card(card, core.page_allocator(data)))
			}
		}

		data.cards = cards[:]
	}

	lists.build_card_grid_page("Mixes", data.cards, phase, false)
}

build_youtube_sign_in_page :: proc(title, text: string) {
	page := kit.page_scroll("youtube sign in")

	if ui.scope(page) {
		kit.page_heading(title)
		build_youtube_sign_in_note(text)
	}
}

// Google refuses a sign-in inside an app, so onlymuse takes the one Helium has.
build_youtube_sign_in_note :: proc(text: string) {
	kit.note(text)
	kit.note(
		"Sign in at music.youtube.com in Helium, then use its sign-in here. macOS asks once to let onlymuse read Helium's key. Choose Always Allow.",
	)

	if kit.action_button("Use Helium's Sign-In", "person.crop.circle", true) {
		is_reading_youtube_sign_in = true
		helper.send_youtube_sign_in()
	}
}

@(private = "file")
is_reading_youtube_sign_in: bool

apply_youtube_cookie :: proc(message: helper.Message) {
	was_signed_in := youtube.is_signed_in()
	youtube.set_cookie(message.cookie)
	is_signed_in := youtube.is_signed_in()

	if is_signed_in != was_signed_in do apple.refresh_all(youtube.PATH_PREFIX)

	if !is_reading_youtube_sign_in do return

	is_reading_youtube_sign_in = false

	switch {
	case is_signed_in:
		kit.show_toast("Signed in to YouTube Music with Helium's sign-in")
	case message.problem == "keychain":
		kit.show_toast("macOS did not let onlymuse read Helium's key")
	case message.problem == "helium":
		kit.show_toast("Could not read Helium's cookies. Check that Helium is installed.")
	case:
		kit.show_toast("Helium is not signed in to YouTube. Sign in at music.youtube.com first.")
	}
}

build_youtube_search_results :: proc(term: string, apple_songs: []core.Catalog_Song, width: f32) {
	songs_list, _ := youtube_lists.watch_youtube_list(
		youtube.to_search_path(term, youtube.SONGS_FILTER),
	)
	videos_list, _ := youtube_lists.watch_youtube_list(
		youtube.to_search_path(term, youtube.VIDEOS_FILTER),
	)
	shown := make([dynamic]core.Catalog_Song, context.temp_allocator)

	for song in songs_list.songs {
		if len(shown) >= SHOWN_YOUTUBE_SONG_COUNT do break

		_, state := matching.watch_match(song)
		if state != .Missing do continue

		is_in_apple_results := false

		for apple_song in apple_songs {
			if !matching.is_same_recording(song, apple_song) do continue

			is_in_apple_results = true
			break
		}

		if !is_in_apple_results do append(&shown, song)
	}

	if len(shown) > 0 {
		section := ui.box(
			"youtube songs",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 0},
		)

		if ui.scope(section) {
			lists.build_shelf_title("From YouTube", true)
			ui.box("", {width = ui.points(1), height = ui.points(6)})

			for song, index in shown {
				if lists.build_song_row(
					fmt.tprintf("%d %s", index, song.id),
					song,
					lists.to_song_subtitle(song),
					playback.is_current_song(song),
				) {
					playback.play_songs(shown[:], index)
				}
			}
		}
	}

	if width <= 0 || len(videos_list.songs) == 0 do return

	cards := make([]apple.Card, len(videos_list.songs), context.temp_allocator)

	for song, index in videos_list.songs {
		cards[index] = {
			id       = song.id,
			kind     = .Song,
			name     = song.name,
			subtitle = song.artist_name,
			artwork  = song.artwork,
			song     = song,
		}
	}

	lists.build_shelf(
		"youtube videos",
		{title = "Videos on YouTube", cards = cards, is_youtube = true, is_wide = true},
		width,
		lists.WIDE_TILE_POINTS,
	)
}
