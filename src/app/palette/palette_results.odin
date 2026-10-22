package palette

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:platform"

@(private)
update_results :: proc() {
	term := strings.to_lower(
		strings.trim_space(kit.field_text(&palette.field)),
		context.temp_allocator,
	)
	songs, song_signature, _ := core.list_library_songs()
	albums, album_signature, _ := core.list_library_albums()
	artists, artist_signature, _ := core.list_library_artists()
	playlists, _, _ := core.list_playlists()

	// Apple Music once the typing rests.
	catalog: apple.Watched
	is_settled := helper.now_ms() - palette.typed_at >= PALETTE_SETTLE_MS
	if term != "" && !is_settled do platform.request_frame_after(PALETTE_SETTLE_MS / 1000.0)
	if term != "" && is_settled {
		catalog = apple.watch(
			fmt.tprintf(
				"/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=4",
				apple.STOREFRONT,
				apple.to_query_text(term),
			),
		)
	}

	signature :=
		((song_signature * 31 + album_signature) * 31 + artist_signature) * 31 +
		catalog.version +
		len(playlists) * 7
	if term == palette.built_term && signature == palette.built_signature do return

	core.retire_arena(palette.arena)
	palette.arena = {}
	_ = virtual.arena_init_growing(&palette.arena)
	allocator := virtual.arena_allocator(&palette.arena)
	palette.built_term = strings.clone(term, allocator)
	palette.built_signature = signature
	results := make([dynamic]Palette_Result, allocator)

	add_actions(&results, term, allocator)
	add_pages(&results, term, playlists, allocator)

	if term != "" {
		names := make([]string, len(artists), context.temp_allocator)
		for card, index in artists do names[index] = card.name
		for index in find_best(names, nil, term) {
			card := artists[index]
			append(
				&results,
				Palette_Result {
					group = "Artists",
					title = strings.clone(card.name, allocator),
					artwork = clone_artwork(card.artwork, allocator),
					is_round = true,
					action = .Open_Card,
					card = core.copy_card(card, allocator),
				},
			)
		}

		names = make([]string, len(albums), context.temp_allocator)
		for card, index in albums do names[index] = card.name
		for index in find_best(names, nil, term) {
			card := albums[index]
			append(
				&results,
				Palette_Result {
					group = "Albums",
					title = strings.clone(card.name, allocator),
					subtitle = strings.clone(card.subtitle, allocator),
					artwork = clone_artwork(card.artwork, allocator),
					action = .Open_Card,
					card = core.copy_card(card, allocator),
				},
			)
		}

		names = make([]string, len(songs), context.temp_allocator)
		others := make([]string, len(songs), context.temp_allocator)
		for song, index in songs {
			names[index] = song.name
			others[index] = song.artist_name
		}
		for index in find_best(names, others, term) {
			song := songs[index]
			append(
				&results,
				Palette_Result {
					group = "Songs",
					title = strings.clone(song.name, allocator),
					subtitle = strings.clone(song.artist_name, allocator),
					artwork = clone_artwork(song.artwork, allocator),
					action = .Play_Library_Song,
					index = index,
				},
			)
		}
	}

	if catalog.phase == .Ready do add_catalog(&results, catalog.body, allocator)

	palette.results = results[:]
	palette.selected = min(palette.selected, max(0, len(results) - 1))
}

// Case aside, the name holds the term.
@(private = "file")
matches :: proc(name, term: string) -> bool {
	return to_match_score(name, term) >= 0
}

// 0 when the name starts with the term, 1 when a word in it does, 2 when it holds it anywhere, -1 when not.
@(private = "file")
to_match_score :: proc(name, term: string) -> int {
	if term == "" do return 0

	lower := strings.to_lower(name, context.temp_allocator)
	at := strings.index(lower, term)
	if at < 0 do return -1
	if at == 0 do return 0

	for start := at; start >= 0; {
		if lower[start - 1] == ' ' || lower[start - 1] == '(' || lower[start - 1] == '-' do return 1

		next := strings.index(lower[start + 1:], term)
		if next < 0 do break
		start += 1 + next
	}

	return 2
}

// The indexes of the best matches, best first, at most a group's worth. A second name, such as a song's
// artist, counts one step lower than the first.
@(private = "file")
find_best :: proc(names, second_names: []string, term: string) -> []int {
	Match :: struct {
		index, score: int,
	}
	found := make([dynamic]Match, context.temp_allocator)

	for name, index in names {
		score := to_match_score(name, term)
		if second_names != nil {
			if second := to_match_score(second_names[index], term);
			   second >= 0 && (score < 0 || second + 1 < score) {
				score = second + 1
			}
		}
		if score >= 0 do append(&found, Match{index, score})
	}

	slice.stable_sort_by(found[:], proc(a, b: Match) -> bool {return a.score < b.score})

	best := make([]int, min(len(found), PALETTE_GROUP_LIMIT), context.temp_allocator)
	for &index, place in best do index = found[place].index

	return best
}

@(private = "file")
add_actions :: proc(
	results: ^[dynamic]Palette_Result,
	term: string,
	allocator := context.allocator,
) {
	Action :: struct {
		title, symbol, shortcut: string,
		action:                  Palette_Action,
	}
	playing, _, has_song := playback.find_playing_song()
	actions := []Action {
		{"Go to Now Playing", "music.note", "", .Navigate},
		{"Play or Pause", "playpause.fill", "", .Play_Pause},
		{"Next Song", "forward.fill", "", .Next},
		{"Previous Song", "backward.fill", "", .Previous},
		{"Shuffle All Songs", "shuffle", "", .Shuffle_All},
		{"Favourite the Song Playing", "heart.circle", "⌘L", .Favourite},
		{"Show Lyrics", "quote.bubble", "", .Show_Lyrics},
		{"Show Up Next", "list.bullet", "", .Show_Up_Next},
	}

	count := 0
	for action in actions {
		if action.action == .Favourite && !has_song do continue
		if !matches(action.title, term) ||
		   count >= (len(actions) if term == "" else PALETTE_GROUP_LIMIT) {
			continue
		}

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
		if action.action == .Favourite do result.subtitle = strings.clone(playing.name, allocator)
		append(results, result)
		count += 1
	}
}

@(private = "file")
add_pages :: proc(
	results: ^[dynamic]Palette_Result,
	term: string,
	playlists: []apple.Card,
	allocator := context.allocator,
) {
	count := 0
	for items in ([][]core.Sidebar_Item {
			core.apple_music_items,
			core.library_items,
			core.console_items,
		}) {
		for item in items {
			if !matches(item.label, term) || count >= PALETTE_GROUP_LIMIT * 2 do continue
			append(
				results,
				Palette_Result {
					group = "Pages",
					title = item.label,
					symbol = item.symbol,
					action = .Navigate,
					page = {kind = item.kind},
				},
			)
			count += 1
		}
	}

	count = 0
	for playlist in playlists {
		if term == "" || !matches(playlist.name, term) || count >= PALETTE_GROUP_LIMIT do continue
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
add_catalog :: proc(
	results: ^[dynamic]Palette_Result,
	body: string,
	allocator := context.allocator,
) {
	Search_Answer :: struct {
		results: struct {
			songs:   apple.Related,
			albums:  apple.Related,
			artists: apple.Related,
		},
	}
	answer: Search_Answer
	_ = core.unmarshal_text(body, &answer)

	for artist in answer.results.artists.data[:min(2, len(answer.results.artists.data))] {
		card := apple.to_card(artist)
		append(
			results,
			Palette_Result {
				group = "Apple Music",
				title = strings.clone(card.name, allocator),
				subtitle = "Artist",
				artwork = clone_artwork(card.artwork, allocator),
				is_round = true,
				action = .Open_Card,
				card = core.copy_card(card, allocator),
			},
		)
	}
	for album in answer.results.albums.data[:min(2, len(answer.results.albums.data))] {
		card := apple.to_card(album)
		append(
			results,
			Palette_Result {
				group = "Apple Music",
				title = strings.clone(card.name, allocator),
				subtitle = fmt.aprintf("Album · %s", card.subtitle, allocator = allocator),
				artwork = clone_artwork(card.artwork, allocator),
				action = .Open_Card,
				card = core.copy_card(card, allocator),
			},
		)
	}
	for resource in answer.results.songs.data[:min(4, len(answer.results.songs.data))] {
		song := apple.to_catalog_song(resource)
		append(
			results,
			Palette_Result {
				group = "Apple Music",
				title = strings.clone(song.name, allocator),
				subtitle = fmt.aprintf("Song · %s", song.artist_name, allocator = allocator),
				artwork = clone_artwork(song.artwork, allocator),
				action = .Play_Song,
				song = core.copy_song(song, allocator),
			},
		)
	}
}

@(private = "file")
clone_artwork :: proc(artwork: apple.Artwork, allocator := context.allocator) -> apple.Artwork {
	return {
		strings.clone(artwork.url, allocator),
		strings.clone(artwork.bg_color, allocator),
		strings.clone(artwork.text_color1, allocator),
	}
}
