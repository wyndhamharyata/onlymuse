package browse

import "core:fmt"
import "core:strings"
import "core:unicode"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/youtube_lists"
import "om:apple"
import "om:ui"

ARTIST_HEADER_POINTS :: 300

ARTIST_ALBUM_POINTS :: 150

SIMILAR_ARTIST_POINTS :: 130

@(private = "file")
Read_Text :: struct {
	key:     string,
	version: int,
	text:    string,
}

@(private = "file")
artist_id_by_name, catalog_artist_name, library_artist_id: Read_Text

@(private = "file")
find_read_text :: proc(read: ^Read_Text, key: string, version: int) -> (string, bool) {
	return read.text, read.key == key && read.version == version
}

@(private = "file")
keep_read_text :: proc(read: ^Read_Text, key: string, version: int, text: string) -> string {
	delete(read.key)
	delete(read.text)
	read^ = {strings.clone(key), version, strings.clone(text)}

	return read.text
}

// Music.app gives a song's artist only as a name.
watch_artist_id :: proc(artist_name: string) -> (string, apple.Phase) {
	watched := apple.watch(
		fmt.tprintf(
			"/v1/catalog/%s/search?term=%s&types=artists&limit=12",
			apple.STOREFRONT,
			apple.to_query_text(artist_name),
		),
	)
	if watched.phase != .Ready do return "", watched.phase
	if id, ok := find_read_text(&artist_id_by_name, artist_name, watched.version); ok {
		return id, .Ready
	}

	answer: apple.Search_Answer
	_ = core.unmarshal_text(watched.body, &answer)

	artists := answer.results.artists.data
	id := artists[0].id if len(artists) > 0 else ""
	for artist in artists do if artist.attributes.name == artist_name do id = artist.id

	return keep_read_text(&artist_id_by_name, artist_name, watched.version, id), .Ready
}

build_artist_page :: proc(page_id: string, name: string) {
	artist_id := page_id

	if artist_id == "" {
		found, phase := watch_artist_id(name)

		if found == "" {
			page := kit.page_scroll("artist")

			if ui.scope(page) {
				kit.note(
					kit.to_phase_text(phase) if phase != .Ready else fmt.tprintf("Apple Music has no artist named %s.", name),
				)
			}

			return
		}

		artist_id = found
	}

	views := "top-songs,latest-release,full-albums,similar-artists"
	path := fmt.tprintf("/v1/catalog/%s/artists/%s?views=%s", apple.STOREFRONT, artist_id, views)
	watched := apple.watch(path)
	library_albums := watch_library_albums_of(find_catalog_artist_name(path, watched))
	data, needs_read := core.find_page_data(
		path,
		core.mix_version(watched.version, library_albums.version),
		watched.phase,
	)
	if needs_read do read_artist(data, watched.body, library_albums)

	page := kit.page_scroll("artist")
	kit.run_bench_scroll(page)

	if ui.scope(page) {
		if watched.phase != .Ready || data.title == "" {
			kit.note(kit.to_phase_text(watched.phase))
			return
		}

		width := kit.to_content_width(page)
		channel := youtube_lists.watch_youtube_artist(data.title)
		detail := data.detail

		if channel.detail != "" {
			detail =
				fmt.tprintf("%s · %s on YouTube", data.detail, channel.detail) if data.detail != "" else fmt.tprintf("%s on YouTube", channel.detail)
		}

		build_artist_header(data, detail, width)
		build_artist_middle(data)
		if width <= 0 do return

		album_tile_points := lists.to_tile_size(width, ARTIST_ALBUM_POINTS, lists.CARD_GAP_POINTS)
		lists.build_card_row("library", "In Your Library", data.library_cards, album_tile_points)
		lists.build_card_row("albums", "Albums", data.cards, album_tile_points)

		for shelf, index in channel.shelves {
			if !is_youtube_only_shelf(shelf) do continue

			lists.build_shelf(fmt.tprintf("youtube %d", index), shelf, width, ARTIST_ALBUM_POINTS)
		}

		build_recent_songs_shelf(artist_id, data.title)
		lists.build_card_row(
			"similar",
			"Similar Artists",
			data.similar,
			lists.to_tile_size(width, SIMILAR_ARTIST_POINTS, lists.CARD_GAP_POINTS),
			true,
		)
	}
}

@(private = "file")
find_catalog_artist_name :: proc(path: string, watched: apple.Watched) -> string {
	if watched.phase != .Ready do return ""
	if name, ok := find_read_text(&catalog_artist_name, path, watched.version); ok do return name

	resources := apple.to_resources(watched.body, context.temp_allocator)
	name := resources[0].attributes.name if len(resources) > 0 else ""

	return keep_read_text(&catalog_artist_name, path, watched.version, name)
}

// Apple's library search misses a term with an apostrophe.
@(private = "file")
watch_library_albums_of :: proc(artist_name: string) -> apple.Watched {
	if artist_name == "" do return {phase = .Loading}

	words := strings.fields_proc(artist_name, proc(character: rune) -> bool {
			return !unicode.is_letter(character) && !unicode.is_digit(character)
		}, context.temp_allocator)
	longest := ""

	for word in words do if len(word) > len(longest) do longest = word

	search := apple.watch(
		fmt.tprintf(
			"/v1/me/library/search?term=%s&types=library-artists&limit=25",
			apple.to_query_text(longest),
		),
	)
	if search.phase != .Ready do return {phase = search.phase, version = search.version}

	id, ok := find_read_text(&library_artist_id, artist_name, search.version)

	if !ok {
		id = keep_read_text(
			&library_artist_id,
			artist_name,
			search.version,
			find_library_artist_id(search.body, artist_name),
		)
	}

	if id == "" do return {phase = .Ready, version = search.version * 1000}

	albums := apple.watch(fmt.tprintf("/v1/me/library/artists/%s/albums", id))
	albums.version += search.version * 1000

	return albums
}

@(private = "file")
find_library_artist_id :: proc(body, artist_name: string) -> string {
	answer: apple.Search_Answer
	_ = core.unmarshal_text(body, &answer)

	for artist in answer.results.library_artists.data {
		if artist.attributes.name == artist_name {
			return artist.id
		}
	}

	return ""
}

@(private = "file")
read_artist :: proc(data: ^core.Page_Data, body: string, library_albums: apple.Watched) {
	allocator := core.page_allocator(data)
	resources := apple.to_resources(body, allocator)
	if len(resources) == 0 do return

	artist := resources[0]
	attributes := artist.attributes

	data.title = attributes.name
	data.detail = attributes.genre_names[0] if len(attributes.genre_names) > 0 else ""
	data.artwork = attributes.artwork

	data.songs = apple.to_catalog_songs(apple.read_view(artist, "top-songs"), allocator)

	data.latest = apple.to_cards(apple.read_view(artist, "latest-release"), allocator)
	data.cards = apple.to_cards(apple.read_view(artist, "full-albums"), allocator)
	data.similar = apple.to_cards(apple.read_view(artist, "similar-artists"), allocator)

	has_library_albums := library_albums.phase == .Ready && library_albums.body != ""

	if has_library_albums {
		data.library_cards = apple.to_cards(
			apple.to_resources(library_albums.body, allocator),
			allocator,
		)
	}
}

@(private = "file")
is_youtube_only_shelf :: proc(shelf: apple.Shelf) -> bool {
	return shelf.is_wide || (len(shelf.cards) > 0 && strings.has_prefix(shelf.cards[0].id, "VL"))
}
