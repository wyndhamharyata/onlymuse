package app

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "om:apple"
import "om:helper"
import "om:platform"
import "om:ui"

PALETTE_POINTS :: 560
PALETTE_TOP_POINTS :: 70
PALETTE_ROW_POINTS :: 36
PALETTE_LIST_POINTS :: 420
// Apple Music is searched once typing rests this long, so each key press does not ask Apple.
PALETTE_SETTLE_MS :: 300
// The most results each group shows.
PALETTE_GROUP_LIMIT :: 5

@(private = "file")
Palette_Action :: enum {
	Navigate,
	Play_Library_Song,
	Play_Song,
	Open_Card,
	Play_Pause,
	Next,
	Previous,
	Shuffle_All,
	Favourite,
	Show_Lyrics,
	Show_Up_Next,
}

@(private = "file")
Palette_Result :: struct {
	group:    string,
	title:    string,
	subtitle: string,
	symbol:   string,
	artwork:  apple.Artwork,
	is_round: bool,
	shortcut: string,
	action:   Palette_Action,
	page:     Page,
	song:     Catalog_Song,
	card:     apple.Card,
	// The song's place in the library, for Play_Library_Song.
	index:    int,
}

@(private = "file")
palette: struct {
	is_open:      bool,
	field:        Text_Field,
	selected:     int,
	// The results, rebuilt into the arena when the term or the data under it changes.
	arena:        virtual.Arena,
	results:      []Palette_Result,
	built_term:   string,
	built_signature: int,
	// When the term last changed, in ms.
	typed_at:     f64,
	opened_frame: int,
	last_mouse:   [2]f32,
}

start_palette :: proc() {
	palette.field.keeps_focus = true
	palette.field.takes_up_down = true
	register_text_field(&palette.field)
}

// Cmd K opens it, and again closes it.
toggle_palette :: proc() {
	if palette.is_open {
		close_palette()
		return
	}

	palette.is_open = true
	palette.selected = 0
	palette.opened_frame = app.frame_count
	palette.built_signature = -1
	set_field_text(&palette.field, "")
	focus_field(&palette.field)
}

// For the tests, which cannot type into a window behind the others: OM_PALETTE opens it with a term.
open_palette_for_test :: proc(term: string) {
	toggle_palette()
	set_field_text(&palette.field, term)
}

@(private = "file")
close_palette :: proc() {
	palette.is_open = false
	palette.field.is_focused = false
}

build_palette :: proc() {
	if !palette.is_open do return

	field := &palette.field
	if field.is_cancelled {
		close_palette()
		return
	}
	if field.is_changed {
		palette.typed_at = helper.now_ms()
		palette.selected = 0
	}

	update_results()

	count := len(palette.results)
	if count > 0 do palette.selected = (palette.selected + field.step + count) % count

	if field.is_submitted && count > 0 {
		run_result(palette.results[palette.selected])
		close_palette()
		return
	}

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box("palette cover", {width = ui.fill(), height = ui.fill(), background = to_color(0x00000059), position = {0, 0}, flags = {.Floating, .Clickable}})
	is_closing := ui.signal(cover).is_clicked && app.frame_count > palette.opened_frame + 1
	picked := -1

	if ui.scope(cover) {
		width := min(PALETTE_POINTS, window_size.x - 40)
		position := [2]f32{(window_size.x - width) / 2, PALETTE_TOP_POINTS}
		ui.box("palette shadow", {width = ui.points(width), height = ui.points(300), corner_radius = 16, background = {0, 0, 0, 0.5}, softness = 40, position = position + {0, 16}, flags = {.Floating}})
		panel := ui.box("palette", {
			width         = ui.points(width),
			height        = ui.fit_children(),
			axis          = .Y,
			padding       = {8, 8, 8, 8},
			gap           = 6,
			corner_radius = 14,
			background    = to_color(0x26262af5),
			border_width  = 1,
			border_color  = to_color(0xffffff1f),
			position      = position,
			flags         = {.Floating, .Clickable},
		})

		if ui.scope(panel) {
			build_text_field(field, "palette field", "Go to a page, an artist, a song, or do something", "magnifyingglass", 40, 16, {0, 0, 0, 0.001})
			picked = build_results()
		}
	}

	palette.last_mouse = ui.mouse_position()

	if picked >= 0 {
		run_result(palette.results[picked])
		is_closing = true
	}
	if is_closing do close_palette()
}

// Groups with a title each. Returns the index of a clicked result, or -1.
@(private = "file")
build_results :: proc() -> int {
	if len(palette.results) == 0 {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, padding = {10, 6, 10, 8}}, "Nothing matches. Apple Music is searched as you pause.")
		return -1
	}

	list := ui.box("palette list", {width = ui.fill(), height = ui.points(min(PALETTE_LIST_POINTS, palette_list_height())), axis = .Y, flags = {.Scroll, .Clip}})
	picked := -1

	if ui.scope(list) {
		group := ""
		for result, index in palette.results {
			if result.group != group {
				group = result.group
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11, font_weight = .Bold, padding = {10, 8, 10, 4}}, strings.to_upper(group, context.temp_allocator))
			}
			if build_result_row(result, index) do picked = index
		}
	}

	return picked
}

@(private = "file")
palette_list_height :: proc() -> f32 {
	groups := 0
	group := ""
	for result in palette.results {
		if result.group != group {
			group = result.group
			groups += 1
		}
	}

	return f32(len(palette.results)) * PALETTE_ROW_POINTS + f32(groups) * 27
}

// Returns true when clicked. The pointer over a row selects it.
@(private = "file")
build_result_row :: proc(result: Palette_Result, index: int) -> bool {
	is_selected := index == palette.selected
	row := ui.box(fmt.tprintf("result %d", index), {
		width         = ui.fill(),
		height        = ui.points(PALETTE_ROW_POINTS),
		axis          = .X,
		align         = .Center,
		gap           = 10,
		padding       = {8, 0, 10, 0},
		corner_radius = 8,
		background    = to_accent_tint(app.accent) if is_selected else {},
		flags         = {.Clickable},
	})
	signal := ui.signal(row)
	// The pointer selects only when it moves, so a row under a still pointer leaves the arrow keys' choice.
	if signal.is_hovered && ui.mouse_position() != palette.last_mouse do palette.selected = index

	if ui.scope(row) {
		if result.artwork.url != "" {
			artwork_box(apple.to_artwork_url(result.artwork, to_artwork_pixels(26)), 26, 13 if result.is_round else 4, to_placeholder(result.artwork, result.title, "music.note"))
		} else {
			icon_box("", result.symbol if result.symbol != "" else "arrow.right", 14, app.accent if is_selected else colors.dim, {width = ui.points(26), height = ui.points(26)})
		}

		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.text, font_size = 13.5, flags = {.Truncate_Text}}, result.title)
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 12, flags = {.Truncate_Text}}, result.subtitle)
		if result.shortcut != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.faint, font_size = 12}, result.shortcut)
		if is_selected do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = app.accent, font_size = 13}, "↵")
	}

	return signal.is_clicked
}

// ---- What matches ----

@(private = "file")
update_results :: proc() {
	term := strings.to_lower(strings.trim_space(field_text(&palette.field)), context.temp_allocator)
	songs, song_signature, _ := list_library_songs()
	albums, album_signature, _ := list_library_albums()
	artists, artist_signature, _ := list_library_artists()
	playlists, _, _ := list_playlists()

	// Apple Music once the typing rests.
	catalog: apple.Watched
	is_settled := helper.now_ms() - palette.typed_at >= PALETTE_SETTLE_MS
	if term != "" && !is_settled do platform.request_frame_after(PALETTE_SETTLE_MS / 1000.0)
	if term != "" && is_settled {
		catalog = apple.watch(fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=4", apple.STOREFRONT, to_query_text(term)))
	}

	signature := ((song_signature * 31 + album_signature) * 31 + artist_signature) * 31 + catalog.version + len(playlists) * 7
	if term == palette.built_term && signature == palette.built_signature do return

	virtual.arena_destroy(&palette.arena)
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
			append(&results, Palette_Result{group = "Artists", title = strings.clone(card.name, allocator), artwork = clone_artwork(card.artwork, allocator), is_round = true, action = .Open_Card, card = clone_card(card, allocator)})
		}

		names = make([]string, len(albums), context.temp_allocator)
		for card, index in albums do names[index] = card.name
		for index in find_best(names, nil, term) {
			card := albums[index]
			append(&results, Palette_Result{group = "Albums", title = strings.clone(card.name, allocator), subtitle = strings.clone(card.subtitle, allocator), artwork = clone_artwork(card.artwork, allocator), action = .Open_Card, card = clone_card(card, allocator)})
		}

		names = make([]string, len(songs), context.temp_allocator)
		others := make([]string, len(songs), context.temp_allocator)
		for song, index in songs {
			names[index] = song.name
			others[index] = song.artist_name
		}
		for index in find_best(names, others, term) {
			song := songs[index]
			append(&results, Palette_Result{group = "Songs", title = strings.clone(song.name, allocator), subtitle = strings.clone(song.artist_name, allocator), artwork = clone_artwork(song.artwork, allocator), action = .Play_Library_Song, index = index})
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
			if second := to_match_score(second_names[index], term); second >= 0 && (score < 0 || second + 1 < score) do score = second + 1
		}
		if score >= 0 do append(&found, Match{index, score})
	}

	slice.stable_sort_by(found[:], proc(a, b: Match) -> bool {return a.score < b.score})

	best := make([]int, min(len(found), PALETTE_GROUP_LIMIT), context.temp_allocator)
	for &index, place in best do index = found[place].index

	return best
}

@(private = "file")
add_actions :: proc(results: ^[dynamic]Palette_Result, term: string, allocator := context.allocator) {
	Action :: struct {
		title, symbol, shortcut: string,
		action:                  Palette_Action,
	}
	playing, _, has_song := find_playing_song()
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
		if !matches(action.title, term) || count >= (len(actions) if term == "" else PALETTE_GROUP_LIMIT) do continue

		result := Palette_Result{group = "Actions", title = action.title, symbol = action.symbol, shortcut = action.shortcut, action = action.action}
		if action.action == .Navigate do result.page = {kind = .Now_Playing}
		if action.action == .Favourite do result.subtitle = strings.clone(playing.name, allocator)
		append(results, result)
		count += 1
	}
}

@(private = "file")
add_pages :: proc(results: ^[dynamic]Palette_Result, term: string, playlists: []apple.Card, allocator := context.allocator) {
	count := 0
	for items in ([][]Sidebar_Item{apple_music_items, library_items}) {
		for item in items {
			if !matches(item.label, term) || count >= PALETTE_GROUP_LIMIT * 2 do continue
			append(results, Palette_Result{group = "Pages", title = item.label, symbol = item.symbol, action = .Navigate, page = {kind = item.kind}})
			count += 1
		}
	}

	count = 0
	for playlist in playlists {
		if term == "" || !matches(playlist.name, term) || count >= PALETTE_GROUP_LIMIT do continue
		name := strings.clone(playlist.name, allocator)
		append(results, Palette_Result{group = "Playlists", title = name, symbol = "music.note.list", action = .Navigate, page = {kind = .Playlist, id = strings.clone(playlist.id, allocator), title = name}})
		count += 1
	}
}

@(private = "file")
add_catalog :: proc(results: ^[dynamic]Palette_Result, body: string, allocator := context.allocator) {
	Search_Answer :: struct {
		results: struct {
			songs:   apple.Related,
			albums:  apple.Related,
			artists: apple.Related,
		},
	}
	answer: Search_Answer
	_ = unmarshal_text(body, &answer)

	for artist in answer.results.artists.data[:min(2, len(answer.results.artists.data))] {
		card := apple.to_card(artist)
		append(results, Palette_Result{group = "Apple Music", title = strings.clone(card.name, allocator), subtitle = "Artist", artwork = clone_artwork(card.artwork, allocator), is_round = true, action = .Open_Card, card = clone_card(card, allocator)})
	}
	for album in answer.results.albums.data[:min(2, len(answer.results.albums.data))] {
		card := apple.to_card(album)
		append(results, Palette_Result{group = "Apple Music", title = strings.clone(card.name, allocator), subtitle = fmt.aprintf("Album · %s", card.subtitle, allocator = allocator), artwork = clone_artwork(card.artwork, allocator), action = .Open_Card, card = clone_card(card, allocator)})
	}
	for resource in answer.results.songs.data[:min(4, len(answer.results.songs.data))] {
		song := apple.to_catalog_song(resource)
		append(results, Palette_Result{group = "Apple Music", title = strings.clone(song.name, allocator), subtitle = fmt.aprintf("Song · %s", song.artist_name, allocator = allocator), artwork = clone_artwork(song.artwork, allocator), action = .Play_Song, song = clone_song_into(song, allocator)})
	}
}

@(private = "file")
clone_artwork :: proc(artwork: apple.Artwork, allocator := context.allocator) -> apple.Artwork {
	return {strings.clone(artwork.url, allocator), strings.clone(artwork.bg_color, allocator), strings.clone(artwork.text_color1, allocator)}
}

@(private = "file")
clone_card :: proc(card: apple.Card, allocator := context.allocator) -> apple.Card {
	cloned := card
	cloned.id = strings.clone(card.id, allocator)
	cloned.name = strings.clone(card.name, allocator)
	cloned.subtitle = strings.clone(card.subtitle, allocator)
	cloned.artwork = clone_artwork(card.artwork, allocator)
	cloned.song = {}

	return cloned
}

@(private = "file")
clone_song_into :: proc(song: Catalog_Song, allocator := context.allocator) -> Catalog_Song {
	cloned := song
	cloned.id = strings.clone(song.id, allocator)
	cloned.name = strings.clone(song.name, allocator)
	cloned.artist_name = strings.clone(song.artist_name, allocator)
	cloned.album_name = strings.clone(song.album_name, allocator)
	cloned.artwork = clone_artwork(song.artwork, allocator)

	return cloned
}

// ---- Doing it ----

@(private = "file")
run_result :: proc(result: Palette_Result) {
	switch result.action {
	case .Navigate:
		page := result.page
		page.id = strings.clone(page.id)
		page.title = strings.clone(page.title)
		navigate(page)
	case .Play_Library_Song:
		songs, _, _ := list_library_songs()
		if result.index < len(songs) do play_songs(songs, result.index)
	case .Play_Song:
		// The queue keeps the song after the palette's results go.
		play_songs([]Catalog_Song{clone_song(result.song)}, 0)
	case .Open_Card:
		card := clone_card(result.card)
		open_card([]apple.Card{card}, 0)
	case .Play_Pause:
		helper.send(`{"type":"playPause"}`)
	case .Next:
		skip_to_next()
	case .Previous:
		skip_to_previous(helper.position_seconds(app.now_playing))
	case .Shuffle_All:
		songs, _, _ := list_library_songs()
		shuffle_songs(songs)
	case .Favourite:
		if song, persistent_id, ok := find_playing_song(); ok do toggle_favourite(song, persistent_id)
	case .Show_Lyrics:
		set_panel(.Lyrics)
	case .Show_Up_Next:
		set_panel(.Up_Next)
	}
}
