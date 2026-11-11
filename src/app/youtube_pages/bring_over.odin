package youtube_pages

import "core:fmt"
import "om:app/core"
import "om:app/lists"
import "om:app/look"
import "om:app/matching"
import "om:app/menus"
import "om:app/youtube_lists"
import "om:apple"
import "om:youtube"
import "thor:kit"
import "thor:ui"

build_bring_over_page :: proc(page: core.Page) {
	if !youtube.is_signed_in() {
		build_youtube_sign_in_page(
			"Bring Over",
			"Sign in to YouTube Music to bring your playlists over to Apple Music.",
		)
		return
	}

	if page.id == "" {
		list, watched := youtube_lists.watch_youtube_list(
			youtube.to_browse_path(youtube.LIBRARY_PLAYLISTS_ID),
		)
		playlists := make([dynamic]apple.Card, context.temp_allocator)

		// Episodes for Later holds podcasts, and Apple Music has no podcasts.
		for card in list.cards {
			if card.id == youtube.PODCAST_EPISODES_ID do continue

			append(&playlists, card)
		}

		lists.build_card_grid_page(
			"Bring Over from YouTube Music",
			playlists[:],
			watched.phase,
			false,
		)
		return
	}

	first, songs, phase := youtube_lists.watch_youtube_songs(youtube.to_list_path(page.id))
	title := first.title if first.title != "" else page.title
	counts := list_match_counts(songs)
	scroll := look.page_scroll("bring_over")

	if ui.scope(scroll) {
		header := ui.box(
			"header",
			{width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10},
		)

		if ui.scope(header) {
			heading := ui.box(
				"heading",
				{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2},
			)

			if ui.scope(heading) {
				kit.heading(title)
				kit.text(
					to_match_summary(counts, len(songs)) if phase == .Ready else youtube_lists.to_youtube_phase_note(phase),
					kit.with_opacity(kit.colors.base_content, 0.7),
				)
			}

			is_ready := phase == .Ready && counts[.Checking] == 0 && len(songs) > 0

			if is_ready && kit.button("bring_over", "Bring Over", "square.and.arrow.down", .Primary).is_activated {
				bring_over(title, songs)
			}
		}

		if phase == .Loading do look.build_loading(title)

		if phase == .Ready {
			kit.text(
				"Each song Apple Music has goes into a new Apple Music playlist. It plays in Apple Music's quality. The others stay in the playlist and play from YouTube.",
				kit.with_opacity(kit.colors.base_content, 0.7),
is_wrapped = true,
			)
			lists.build_song_rows(songs)
		}
	}
}

@(private = "file")
list_match_counts :: proc(songs: []core.Catalog_Song) -> [matching.Match_State]int {
	counts: [matching.Match_State]int

	for song in songs {
		_, state := matching.watch_match(song)
		counts[state] += 1
	}

	return counts
}

@(private = "file")
to_match_summary :: proc(counts: [matching.Match_State]int, total: int) -> string {
	text := fmt.tprintf(
		"%d songs · %d on Apple Music · %d only on YouTube",
		total,
		counts[.Found],
		counts[.Missing],
	)

	if counts[.Checking] > 0 do text = fmt.tprintf("%s · checking %d", text, counts[.Checking])

	return text
}

@(private = "file")
bring_over :: proc(name: string, songs: []core.Catalog_Song) {
	apple_songs := make([dynamic]core.Catalog_Song, context.temp_allocator)
	extra := make([dynamic]youtube_lists.Playlist_YouTube_Song, context.temp_allocator)
	after := youtube_lists.PLAYLIST_START

	for song in songs {
		playable := matching.watch_playable(song)

		if youtube.is_song_id(playable.id) {
			append(&extra, youtube_lists.Playlist_YouTube_Song{after, playable})
			continue
		}

		append(&apple_songs, playable)
		after = playable.id
	}

	done_text := fmt.tprintf(
		"Brought over %s with %d songs from Apple Music and %d from YouTube",
		name,
		len(apple_songs),
		len(extra),
	)

	menus.create_playlist(name, apple_songs[:], extra[:], done_text, true)
}
