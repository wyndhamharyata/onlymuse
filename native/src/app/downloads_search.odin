package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:apple"
import "om:platform"
import "om:ui"

unmarshal_text :: proc(text: string, value: ^$T) -> json.Unmarshal_Error {
	return json.unmarshal_string(text, value, allocator = context.temp_allocator)
}

Download :: struct {
	catalog_id:  string,
	is_lossless: bool,
}

downloads: struct {
	mutex:       sync.Mutex,
	list:        []Download,
	// Counts up with each finished scan.
	version:     int,
	is_scanning: bool,
}

// Music.app keeps each downloaded Apple Music song as a package of its own, two folders down.
@(private = "file")
download_folder :: proc() -> string {
	return fmt.tprintf("%s/Music/Music/Media.localized/Apple Music", os.get_env("HOME", context.temp_allocator))
}

// The stream's file name holds the catalog ID after "_A", and ends in "_alac" for a lossless download.
@(private = "file")
read_download :: proc(boot_path: string) -> (Download, bool) {
	bytes, error := os.read_entire_file(boot_path, context.temp_allocator)
	if error != nil do return {}, false

	boot := string(bytes)
	if !strings.contains(boot, "<Complete>YES</Complete>") do return {}, false

	start := strings.index(boot, "_A")
	for start >= 0 {
		rest := boot[start + 2:]
		digits := 0
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' do digits += 1

		if digits > 0 && strings.has_prefix(rest[digits:], "_audio_") {
			stream_end := strings.index(rest, ".m3u8\"")
			is_lossless := stream_end > 0 && strings.has_suffix(rest[:stream_end], "_alac")

			return {strings.clone(rest[:digits]), is_lossless}, true
		}

		next := strings.index(rest, "_A")
		start = start + 2 + next if next >= 0 else -1
	}

	return {}, false
}

@(private = "file")
scan_downloads :: proc() {
	found := make([dynamic]Download)
	artists, _ := os.read_all_directory_by_path(download_folder(), context.temp_allocator)

	for artist in artists {
		albums, _ := os.read_all_directory_by_path(artist.fullpath, context.temp_allocator)

		for album in albums {
			songs, _ := os.read_all_directory_by_path(album.fullpath, context.temp_allocator)

			for song in songs {
				if !strings.has_suffix(song.name, ".movpkg") do continue
				if download, ok := read_download(fmt.tprintf("%s/boot.xml", song.fullpath)); ok do append(&found, download)
			}
		}
		free_all(context.temp_allocator)
	}

	sync.guard(&downloads.mutex)
	downloads.list = found[:]
	downloads.version += 1
	downloads.is_scanning = false
	platform.wake()
}

// The quality comes from the file Music.app saved, not from what Apple offers.
build_downloaded_page :: proc() {
	list: []Download
	scan_version: int
	{
		sync.guard(&downloads.mutex)
		if !downloads.is_scanning && downloads.version == 0 {
			downloads.is_scanning = true
			thread.create_and_start(scan_downloads, self_cleanup = true)
		}
		list = downloads.list
		scan_version = downloads.version
	}

	if scan_version == 0 {
		build_song_list_page("Downloaded", "", nil, .Loading)
		return
	}

	// Answers in batches of 100 IDs, in the order of the IDs.
	signature := scan_version
	phase := apple.Phase.Ready
	bodies := make([dynamic]string, context.temp_allocator)

	for first := 0; first < len(list); first += 100 {
		ids := make([dynamic]string, context.temp_allocator)
		for download in list[first:min(first + 100, len(list))] do append(&ids, download.catalog_id)

		watched := apple.watch(fmt.tprintf("/v1/catalog/%s/songs?ids=%s", apple.STOREFRONT, strings.join(ids[:], ",", context.temp_allocator)))
		signature = signature * 31 + watched.version
		if watched.phase != .Ready do phase = watched.phase
		append(&bodies, watched.body)
	}

	data, is_stale := find_page_data("downloaded", signature, phase)

	if is_stale && phase == .Ready {
		read_library_songs(data, bodies[:])
		lossless_count := 0

		for &song in data.songs {
			for download in list {
				if download.catalog_id != song.id do continue
				song.is_lossless = download.is_lossless
				if download.is_lossless do lossless_count += 1
				break
			}
		}

		slice.sort_by(data.songs, proc(a, b: Catalog_Song) -> bool {return a.name < b.name})
		data.detail = fmt.aprintf("%d lossless", lossless_count, allocator = page_allocator(data))
	}

	build_song_list_page("Downloaded", data.detail, data.songs, phase)
}

SHOWN_SEARCH_SONG_COUNT :: 6
TOP_RESULT_POINTS :: 180

build_search_page :: proc(term: string) {
	path := fmt.tprintf("/v1/catalog/%s/search?term=%s&types=songs,albums,artists&limit=12", apple.STOREFRONT, to_query_text(term))
	watched := apple.watch(path)
	data, is_stale := find_page_data(path, watched.version, watched.phase)

	if is_stale && watched.phase == .Ready {
		Search_Answer :: struct {
			results: struct {
				songs:   apple.Related,
				albums:  apple.Related,
				artists: apple.Related,
			},
		}
		allocator := page_allocator(data)
		answer: Search_Answer
		_ = json.unmarshal_string(watched.body, &answer, allocator = allocator)

		songs := make([]Catalog_Song, len(answer.results.songs.data), allocator)
		for song, index in answer.results.songs.data do songs[index] = apple.to_catalog_song(song)
		data.songs = songs
		data.cards = apple.list_cards(answer.results.albums.data, allocator)
		data.similar = apple.list_cards(answer.results.artists.data, allocator)
	}

	page := page_scroll("search")

	if ui.scope(page) {
		page_heading(fmt.tprintf("Results for \"%s\"", term))

		if watched.phase != .Ready {
			note(phase_note(watched.phase))
			return
		}

		if len(data.songs) + len(data.cards) + len(data.similar) == 0 {
			note(fmt.tprintf("Apple Music has nothing for \"%s\".", term))
			return
		}

		build_search_top(data)

		width := page.size.x - page.style.padding.x - page.style.padding.z
		if width > 0 {
			build_card_row("albums", "Albums", data.cards, fit_tile_size(width, ARTIST_ALBUM_POINTS, CARD_GAP_POINTS))
			build_card_row("artists", "Artists", data.similar, fit_tile_size(width, SIMILAR_ARTIST_POINTS, CARD_GAP_POINTS), true)
		}
	}
}

@(private = "file")
build_search_top :: proc(data: ^Page_Data) {
	top := ui.box("top", {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 28})

	if ui.scope(top) {
		if len(data.similar) > 0 {
			result := ui.box("top result", {width = ui.points(TOP_RESULT_POINTS), height = ui.fit_children(), axis = .Y, gap = 10})

			if ui.scope(result) {
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold}, "Top Result")
				if build_card_tile("top artist", data.similar[0], TOP_RESULT_POINTS, true) do open_card(data.similar, 0)
			}
		}

		songs := data.songs[:min(len(data.songs), SHOWN_SEARCH_SONG_COUNT)]
		list := ui.box("songs", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 0})
		current, is_playing := find_queue_song(app.now_playing.song.persistent_id)

		if ui.scope(list) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.text, font_size = 17, font_weight = .Bold, padding = {0, 0, 0, 10}}, "Songs")

			for song, index in songs {
				subtitle := fmt.tprintf("%s · %s", song.artist_name, song.album_name)
				if build_song_row(fmt.tprintf("%d %s", index, song.id), song, subtitle, is_playing && current.id == song.id) do play_songs(songs, index)
			}
		}
	}
}
