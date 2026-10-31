package palette

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:platform"

MAX_PAGE_RESULT_COUNT :: MAX_GROUP_RESULT_COUNT * 2

CATALOG_SEARCH_LIMIT :: 4

CATALOG_CARD_COUNT :: 2

@(private)
watch_results :: proc() {
	term := strings.to_lower(
		strings.trim_space(kit.to_field_text(&palette.field)),
		context.temp_allocator,
	)
	songs, song_signature, _ := core.watch_library_songs()
	albums, album_signature, _ := core.watch_library_albums()
	artists, artist_signature, _ := core.watch_library_artists()
	playlists, _, _ := core.watch_playlists()

	catalog: apple.Watched
	is_settled := helper.now_ms() - palette.typed_at_ms >= PALETTE_SETTLE_MS
	is_search_due := term != "" && is_settled
	if term != "" && !is_settled do platform.request_frame_after(PALETTE_SETTLE_MS / 1000.0)

	if is_search_due {
		catalog = apple.watch(
			fmt.tprintf(
				"/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=%d",
				apple.STOREFRONT,
				apple.to_query_text(term),
				CATALOG_SEARCH_LIMIT,
			),
		)
	}

	signature := core.mix_version(song_signature, album_signature)
	signature = core.mix_version(signature, artist_signature)
	signature = core.mix_version(signature, catalog.version)
	signature = core.mix_version(signature, len(playlists))
	is_built := term == palette.built_term && signature == palette.built_signature
	if is_built do return

	core.retire_arena(palette.arena)
	palette.arena = {}
	_ = virtual.arena_init_growing(&palette.arena)
	allocator := virtual.arena_allocator(&palette.arena)

	palette.built_term = strings.clone(term, allocator)
	palette.built_signature = signature
	results := make([dynamic]Palette_Result, allocator)

	append_actions(&results, term, allocator)
	append_pages(&results, term, playlists, allocator)

	if term != "" {
		names := make([]string, len(artists), context.temp_allocator)
		for card, index in artists do names[index] = card.name

		for index in list_best_indexes(names, nil, term) {
			append_card(&results, artists[index], "Artists", "", allocator)
		}

		names = make([]string, len(albums), context.temp_allocator)
		for card, index in albums do names[index] = card.name

		for index in list_best_indexes(names, nil, term) {
			card := albums[index]
			append_card(&results, card, "Albums", card.subtitle, allocator)
		}

		names = make([]string, len(songs), context.temp_allocator)
		artist_names := make([]string, len(songs), context.temp_allocator)

		for song, index in songs {
			names[index] = song.name
			artist_names[index] = song.artist_name
		}

		for index in list_best_indexes(names, artist_names, term) {
			song := songs[index]
			append(
				&results,
				Palette_Result {
					group = "Songs",
					title = strings.clone(song.name, allocator),
					subtitle = strings.clone(song.artist_name, allocator),
					artwork = core.copy_artwork(song.artwork, allocator),
					action = .Play_Library_Song,
					index = index,
				},
			)
		}
	}

	if catalog.phase == .Ready do append_catalog(&results, catalog.body, allocator)

	palette.results = results[:]
	palette.selected_index = min(palette.selected_index, max(0, len(results) - 1))
}

@(private = "file")
has_term :: proc(name, term: string) -> bool {
	return to_term_score(name, term) >= 0
}

@(private = "file")
to_term_score :: proc(name, term: string) -> int {
	lower := strings.to_lower(name, context.temp_allocator)
	at := strings.index(lower, term)
	if at < 0 do return -1
	if at == 0 do return 0

	for start := at; start >= 0; {
		before := lower[start - 1]
		is_word_start := before == ' ' || before == '(' || before == '-'
		if is_word_start do return 1

		next := strings.index(lower[start + 1:], term)
		if next < 0 do break
		start += 1 + next
	}

	return 2
}

@(private = "file")
list_best_indexes :: proc(names, second_names: []string, term: string) -> []int {
	Scored_Name :: struct {
		index, score: int,
	}
	found := make([dynamic]Scored_Name, context.temp_allocator)

	for name, index in names {
		score := to_term_score(name, term)
		second_score := to_term_score(second_names[index], term) if second_names != nil else -1

		is_second_better := second_score >= 0 && (score < 0 || second_score + 1 < score)

		if is_second_better do score = second_score + 1
		if score >= 0 do append(&found, Scored_Name{index, score})
	}

	slice.stable_sort_by(found[:], proc(a, b: Scored_Name) -> bool {return a.score < b.score})

	best := make([]int, min(len(found), MAX_GROUP_RESULT_COUNT), context.temp_allocator)
	for &index, place in best do index = found[place].index

	return best
}

@(private = "file")
append_actions :: proc(results: ^[dynamic]Palette_Result, term: string, allocator: mem.Allocator) {
	Action :: struct {
		title, symbol, shortcut: string,
		action:                  Palette_Action,
	}
	playing, _, has_song := playback.find_playing_song()
	player_action :=
		"Play in Apple's web player" if core.app.drives_music_app else "Play in Music.app"
	player_subtitle :=
		"Favourites, downloads and lossless turn off" if core.app.drives_music_app else "Favourites, downloads, lossless and gapless playback"
	actions := []Action {
		{"Go to Now Playing", "music.note", "", .Navigate},
		{"Play or Pause", "playpause.fill", "", .Play_Pause},
		{"Next Song", "forward.fill", "", .Next},
		{"Previous Song", "backward.fill", "", .Previous},
		{"Shuffle All Songs", "shuffle", "", .Shuffle_All},
		{player_action, "music.note", "", .Toggle_Player},
		{"Favourite the Song Playing", "heart.circle", "⌘L", .Favourite},
		{"Show Lyrics", "quote.bubble", "", .Show_Lyrics},
		{"Show Up Next", "list.bullet", "", .Show_Up_Next},
	}

	max_count := len(actions) if term == "" else MAX_GROUP_RESULT_COUNT
	count := 0

	for action in actions {
		if action.action == .Favourite && !has_song do continue
		if !has_term(action.title, term) || count >= max_count do continue

		result := Palette_Result {
			group    = "Actions",
			title    = action.title,
			symbol   = action.symbol,
			shortcut = action.shortcut,
			action   = action.action,
		}

		if action.action == .Navigate do result.page = {
			kind = .Now_Playing,
		}
		if action.action == .Favourite {
			if playback.can_favourite(playing) {
				result.subtitle = strings.clone(playing.name, allocator)
			} else {
				result.is_disabled = true
				result.subtitle = strings.clone("Needs Music.app", allocator)
			}
		}

		if action.action == .Toggle_Player do result.subtitle = strings.clone(player_subtitle, allocator)

		append(results, result)
		count += 1
	}
}

@(private = "file")
append_pages :: proc(
	results: ^[dynamic]Palette_Result,
	term: string,
	playlists: []apple.Card,
	allocator: mem.Allocator,
) {
	count := 0

	for items in ([][]core.Sidebar_Item {
			core.apple_music_items,
			core.library_items,
			core.console_items,
		}) {
		for item in items {
			if !has_term(item.label, term) || count >= MAX_PAGE_RESULT_COUNT do continue

			result := Palette_Result {
				group  = "Pages",
				title  = item.label,
				symbol = item.symbol,
				action = .Navigate,
				page   = item.page,
			}

			if !core.app.drives_music_app && item.page.kind == .Downloaded {
				result.is_disabled = true
				result.subtitle = strings.clone("Needs Music.app", allocator)
			}

			append(results, result)
			count += 1
		}
	}

	count = 0

	for playlist in playlists {
		is_shown := term != "" && has_term(playlist.name, term) && count < MAX_GROUP_RESULT_COUNT
		if !is_shown do continue

		name := strings.clone(playlist.name, allocator)
		append(
			results,
			Palette_Result {
				group = "Playlists",
				title = name,
				symbol = "music.note.list",
				action = .Navigate,
				page = {
					kind = .Playlist,
					id = strings.clone(playlist.id, allocator),
					title = name,
				},
			},
		)
		count += 1
	}
}

@(private = "file")
append_catalog :: proc(results: ^[dynamic]Palette_Result, body: string, allocator: mem.Allocator) {
	answer: apple.Search_Answer
	_ = core.unmarshal_text(body, &answer)

	artists := answer.results.artists.data
	albums := answer.results.albums.data
	songs := answer.results.songs.data

	for artist in artists[:min(CATALOG_CARD_COUNT, len(artists))] {
		append_card(results, apple.to_card(artist), "Apple Music", "Artist", allocator)
	}

	for album in albums[:min(CATALOG_CARD_COUNT, len(albums))] {
		card := apple.to_card(album)
		subtitle := fmt.tprintf("Album · %s", card.subtitle)
		append_card(results, card, "Apple Music", subtitle, allocator)
	}

	for resource in songs[:min(CATALOG_SEARCH_LIMIT, len(songs))] {
		song := apple.to_catalog_song(resource)
		append(
			results,
			Palette_Result {
				group = "Apple Music",
				title = strings.clone(song.name, allocator),
				subtitle = fmt.aprintf("Song · %s", song.artist_name, allocator = allocator),
				artwork = core.copy_artwork(song.artwork, allocator),
				action = .Play_Song,
				song = core.copy_song(song, allocator),
			},
		)
	}
}

@(private = "file")
append_card :: proc(
	results: ^[dynamic]Palette_Result,
	card: apple.Card,
	group, subtitle: string,
	allocator: mem.Allocator,
) {
	append(
		results,
		Palette_Result {
			group = group,
			title = strings.clone(card.name, allocator),
			subtitle = strings.clone(subtitle, allocator),
			artwork = core.copy_artwork(card.artwork, allocator),
			is_round = card.kind == .Artist,
			action = .Open_Card,
			card = core.copy_card(card, allocator),
		},
	)
}
