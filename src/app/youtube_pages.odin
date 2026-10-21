package app

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "om:apple"
import "om:helper"
import "om:store"
import "om:ui"
import "om:youtube"

// A long YouTube list stops after this many parts of about 100 songs.
MAX_YOUTUBE_PART_COUNT :: 50
SHOWN_YOUTUBE_SONG_COUNT :: 6

// ---- Reading YouTube's answers ----

@(private = "file")
Parsed_List :: struct {
	arena:   virtual.Arena,
	version: int,
	list:    youtube.List,
}

// Each answer read once per version, as reading a large one takes milliseconds.
@(private = "file")
parsed_lists: map[string]^Parsed_List

// The list lives until its answer's version changes.
watch_youtube_list :: proc(path: string) -> (youtube.List, apple.Watched) {
	watched := apple.watch(path)
	if watched.phase != .Ready do return {}, watched

	parsed := parsed_lists[path] or_else nil

	if parsed == nil {
		parsed = new(Parsed_List)
		parsed_lists[strings.clone(path)] = parsed
	}

	if parsed.version != watched.version {
		virtual.arena_destroy(&parsed.arena)
		parsed^ = {}
		_ = virtual.arena_init_growing(&parsed.arena)
		parsed.version = watched.version
		parsed.list = youtube.to_list(watched.body, virtual.arena_allocator(&parsed.arena))
	}

	return parsed.list, watched
}

// The songs of every part of a long list, and the first part, which holds the header.
watch_youtube_songs :: proc(path: string) -> (first: youtube.List, songs: []Catalog_Song, phase: apple.Phase) {
	watched: apple.Watched
	first, watched = watch_youtube_list(path)
	signature := watched.version
	phase = watched.phase
	parts := make([dynamic]youtube.List, context.temp_allocator)
	if phase == .Ready do append(&parts, first)

	for token := first.continuation; phase == .Ready && token != "" && len(parts) < MAX_YOUTUBE_PART_COUNT; {
		part, part_watched := watch_youtube_list(youtube.continuation_path(token))
		signature = signature * 31 + part_watched.version

		if part_watched.phase == .Loading do phase = .Loading
		if part_watched.phase != .Ready || len(part.songs) == 0 do break

		append(&parts, part)
		token = part.continuation
	}

	data, is_stale := find_page_data(path, signature, phase)

	if is_stale && phase == .Ready {
		all := make([dynamic]Catalog_Song, page_allocator(data))
		for part in parts do append(&all, ..part.songs)
		data.songs = all[:]
	}

	return first, data.songs, phase
}

youtube_phase_note :: proc(phase: apple.Phase) -> string {
	return "YouTube Music could not be reached." if phase == .Failed else "Loading…"
}

// ---- Pages ----

build_youtube_playlist_page :: proc(page: Page) {
	if page.id == youtube.LIKED_ID && !youtube.is_signed_in() {
		build_youtube_sign_in_page("Liked Music", "Sign in to YouTube Music to see the songs you liked there.")
		return
	}

	first, songs, phase := watch_youtube_songs(youtube.list_path(page.id))
	title := first.title if first.title != "" else page.title

	build_song_list_page(title, first.subtitle, songs, phase)
}

// YouTube's mixes for you are on its home page, as playlists whose IDs start with "RD".
build_youtube_mixes_page :: proc() {
	if !youtube.is_signed_in() {
		build_youtube_sign_in_page("Mixes", "Sign in to YouTube Music to see the mixes it made for you.")
		return
	}

	list, watched := watch_youtube_list(youtube.browse_path(youtube.HOME_ID))
	data, is_stale := find_page_data("youtube mixes", watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		cards := make([dynamic]apple.Card, page_allocator(data))
		seen := make(map[string]bool, context.temp_allocator)

		for shelf in list.shelves {
			for card in shelf.cards {
				is_mix := card.kind == .YouTube_Playlist && (strings.has_prefix(card.id, "RD") || strings.has_prefix(card.id, "VLRD"))
				if !is_mix || seen[card.id] do continue

				seen[card.id] = true
				append(&cards, card)
			}
		}
		data.cards = cards[:]
	}

	build_card_grid_page("Mixes", data.cards, watched.phase, false)
}

build_youtube_sign_in_page :: proc(title, text: string) {
	page := page_scroll("youtube sign in")

	if ui.scope(page) {
		page_heading(title)
		build_youtube_sign_in_note(text)
	}
}

// Google refuses a sign-in inside an app, so onlymuse takes the one Helium has.
build_youtube_sign_in_note :: proc(text: string) {
	note(text)
	note("Sign in at music.youtube.com in Helium, then use its sign-in here. macOS asks once to let onlymuse read Helium's key. Choose Always Allow.")
	if action_button("Use Helium's Sign-In", "person.crop.circle", true) {
		is_reading_youtube_sign_in = true
		helper.send(`{"type":"youtubeSignIn"}`)
	}
}

// Set by the button, so the answer says how it went.
@(private = "file")
is_reading_youtube_sign_in: bool

apply_youtube_cookie :: proc(message: helper.Message) {
	was_signed_in := youtube.is_signed_in()
	youtube.set_cookie(message.cookie)
	is_signed_in := youtube.is_signed_in()

	// Answers saved signed out, such as an empty Liked Music, are asked for again.
	if is_signed_in != was_signed_in do apple.refresh_all(youtube.PATH_PREFIX)

	if !is_reading_youtube_sign_in do return

	is_reading_youtube_sign_in = false
	switch {
	case is_signed_in:
		show_toast("Signed in to YouTube Music with Helium's sign-in")
	case message.problem == "keychain":
		show_toast("macOS did not let onlymuse read Helium's key")
	case message.problem == "helium":
		show_toast("Could not read Helium's cookies. Is Helium installed?")
	case:
		show_toast("Helium is not signed in to YouTube. Sign in at music.youtube.com first.")
	}
}

// The YouTube playlists in the library, or one of them with what each song plays from.
build_bring_over_page :: proc(page: Page) {
	if !youtube.is_signed_in() {
		build_youtube_sign_in_page("Bring Over", "Sign in to YouTube Music to bring your playlists over to Apple Music.")
		return
	}

	if page.id == "" {
		list, watched := watch_youtube_list(youtube.browse_path(youtube.LIBRARY_PLAYLISTS_ID))
		build_card_grid_page("Bring Over from YouTube Music", list.cards, watched.phase, false)
		return
	}

	first, songs, phase := watch_youtube_songs(youtube.list_path(page.id))
	title := first.title if first.title != "" else page.title
	counts := count_matches(songs)
	scroll := page_scroll("bring over")

	if ui.scope(scroll) {
		header := ui.box("header", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10})

		if ui.scope(header) {
			heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

			if ui.scope(heading) {
				page_heading(title)
				text_box(to_match_summary(counts, len(songs)) if phase == .Ready else youtube_phase_note(phase), colors.dim)
			}

			is_ready := phase == .Ready && counts[.Checking] == 0 && len(songs) > 0
			if is_ready && action_button("Bring Over", "square.and.arrow.down", true) do bring_over(title, songs)
		}

		if phase == .Ready {
			note("Each song Apple Music has goes into a new Apple Music playlist, and plays in its quality. The others stay in the playlist and play from YouTube.")
			build_song_rows(scroll, songs)
		}
	}
}

@(private = "file")
count_matches :: proc(songs: []Catalog_Song) -> [Match_State]int {
	counts: [Match_State]int
	for song in songs {
		_, state := find_match(song)
		counts[state] += 1
	}

	return counts
}

@(private = "file")
to_match_summary :: proc(counts: [Match_State]int, total: int) -> string {
	text := fmt.tprintf("%d songs · %d on Apple Music · %d only on YouTube", total, counts[.Found], counts[.Missing])
	if counts[.Checking] > 0 do text = fmt.tprintf("%s · checking %d", text, counts[.Checking])

	return text
}

// The Apple songs make the new playlist. A song only on YouTube is kept after the Apple song before it.
@(private = "file")
bring_over :: proc(name: string, songs: []Catalog_Song) {
	apple_songs := make([dynamic]Catalog_Song, context.temp_allocator)
	extra := make([dynamic]Playlist_YouTube_Song, context.temp_allocator)
	after := PLAYLIST_START

	for song in songs {
		playable := to_playable(song)

		if youtube.is_song_id(playable.id) {
			append(&extra, Playlist_YouTube_Song{after, playable})
			continue
		}

		append(&apple_songs, playable)
		after = playable.id
	}

	done_text := fmt.tprintf("Brought over %s: %d songs from Apple Music, %d from YouTube", name, len(apple_songs), len(extra))
	create_playlist(name, apple_songs[:], extra[:], done_text, true)
}

// ---- Home, search and artists ----

// Apple's shelves with YouTube's between them, one of each in turn.
merge_youtube_shelves :: proc(apple_shelves: []apple.Shelf, allocator := context.allocator) -> (shelves: []apple.Shelf, version: int) {
	list, watched := watch_youtube_list(youtube.browse_path(youtube.HOME_ID))
	if watched.phase != .Ready do return apple_shelves, watched.version

	merged := make([dynamic]apple.Shelf, allocator)

	for index in 0 ..< max(len(apple_shelves), len(list.shelves)) {
		if index < len(apple_shelves) do append(&merged, apple_shelves[index])
		if index < len(list.shelves) do append(&merged, list.shelves[index])
	}

	return merged[:], watched.version
}

// Songs Apple lacks, once its catalog has been checked for each, and YouTube's videos.
build_youtube_search_results :: proc(term: string, apple_songs: []Catalog_Song, width: f32) {
	songs_list, _ := watch_youtube_list(youtube.search_path(term, youtube.SONGS_FILTER))
	videos_list, _ := watch_youtube_list(youtube.search_path(term, youtube.VIDEOS_FILTER))
	shown := make([dynamic]Catalog_Song, context.temp_allocator)

	for song in songs_list.songs {
		if len(shown) >= SHOWN_YOUTUBE_SONG_COUNT do break

		is_in_apple_results := false
		for apple_song in apple_songs do if is_same_recording(song, apple_song) do is_in_apple_results = true

		_, state := find_match(song)
		if !is_in_apple_results && state == .Missing do append(&shown, song)
	}

	if len(shown) > 0 {
		section := ui.box("youtube songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 0})
		current, is_playing := find_queue_song(app.now_playing.song.persistent_id)

		if ui.scope(section) {
			build_shelf_title("From YouTube", true)
			ui.box("", {width = ui.points(1), height = ui.points(6)})

			for song, index in shown {
				if build_song_row(fmt.tprintf("%d %s", index, song.id), song, to_song_subtitle(song), is_playing && is_same_queue_song(current, song)) do play_songs(shown[:], index)
			}
		}
	}

	if width <= 0 || len(videos_list.songs) == 0 do return

	cards := make([]apple.Card, len(videos_list.songs), context.temp_allocator)
	for song, index in videos_list.songs do cards[index] = {id = song.id, kind = .Song, name = song.name, subtitle = song.artist_name, artwork = song.artwork, song = song}
	build_shelf("youtube videos", {title = "Videos on YouTube", cards = cards, is_youtube = true, is_wide = true}, width, WIDE_TILE_POINTS)
}

// The YouTube channel with the artist's name, found by YouTube's artist search.
watch_youtube_artist :: proc(name: string) -> youtube.List {
	if name == "" do return {}

	search, _ := watch_youtube_list(youtube.search_path(name, youtube.ARTISTS_FILTER))
	key := to_match_key(name)

	for card in search.cards {
		if card.kind != .YouTube_Artist || to_match_key(card.name) != key do continue

		channel, _ := watch_youtube_list(youtube.browse_path(card.id))

		return channel
	}

	return {}
}

// ---- Playlists with songs from both ----

// A library playlist can hold songs only on YouTube. Apple's playlist cannot, so onlymuse keeps them,
// each after the Apple song it followed, by that song's catalog ID.
Playlist_YouTube_Song :: struct {
	after: string,
	song:  Catalog_Song,
}

// after for a song before every Apple song. An empty after puts it at the end.
PLAYLIST_START :: "start"

// By library playlist ID, under the state key "playlistYouTubeSongs".
@(private = "file")
playlist_youtube_songs: map[string][dynamic]Playlist_YouTube_Song

@(private = "file")
is_playlist_songs_read: bool

// Counts up with each change, so a playlist page reads its songs again.
playlist_youtube_version: int

@(private = "file")
read_playlist_youtube_songs :: proc() {
	if is_playlist_songs_read do return

	is_playlist_songs_read = true
	if text, ok := store.find_state("playlistYouTubeSongs", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &playlist_youtube_songs)
	}
}

@(private = "file")
save_playlist_youtube_songs :: proc() {
	playlist_youtube_version += 1
	bytes, error := json.marshal(playlist_youtube_songs, allocator = context.temp_allocator)
	if error == nil do store.save_state("playlistYouTubeSongs", string(bytes))
}

add_playlist_youtube_songs :: proc(playlist_id: string, songs: []Playlist_YouTube_Song) {
	read_playlist_youtube_songs()

	if playlist_id not_in playlist_youtube_songs do playlist_youtube_songs[strings.clone(playlist_id)] = {}

	list := &playlist_youtube_songs[playlist_id]
	for song in songs do append(list, Playlist_YouTube_Song{strings.clone(song.after), clone_song(song.song)})
	save_playlist_youtube_songs()
}

remove_playlist_youtube_song :: proc(playlist_id, song_id: string) {
	read_playlist_youtube_songs()

	list, ok := &playlist_youtube_songs[playlist_id]
	if !ok do return

	for song, index in list {
		if song.song.id != song_id do continue

		ordered_remove(list, index)
		break
	}
	save_playlist_youtube_songs()
}

is_playlist_youtube_song :: proc(playlist_id, song_id: string) -> bool {
	read_playlist_youtube_songs()

	for song in playlist_youtube_songs[playlist_id] or_else {} do if song.song.id == song_id do return true

	return false
}

// The playlist's Apple songs with its YouTube songs back in their places.
merge_playlist_youtube_songs :: proc(playlist_id: string, songs: []Catalog_Song, allocator := context.allocator) -> []Catalog_Song {
	read_playlist_youtube_songs()

	extra := playlist_youtube_songs[playlist_id] or_else {}
	if len(extra) == 0 do return songs

	merged := make([dynamic]Catalog_Song, allocator)
	placed := make([]bool, len(extra), context.temp_allocator)

	place_after(&merged, extra, placed, PLAYLIST_START)
	for song in songs {
		append(&merged, song)
		place_after(&merged, extra, placed, song.id)
	}
	for song, index in extra do if !placed[index] do append(&merged, song.song)

	return merged[:]
}

@(private = "file")
place_after :: proc(merged: ^[dynamic]Catalog_Song, extra: [dynamic]Playlist_YouTube_Song, placed: []bool, after: string) {
	for song, index in extra {
		if placed[index] || song.after != after do continue

		append(merged, song.song)
		placed[index] = true
	}
}
