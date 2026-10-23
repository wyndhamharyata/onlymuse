package browse

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:app/core"
import "om:app/lists"
import "om:apple"
import "om:platform"

Download :: struct {
	catalog_id:  string,
	is_lossless: bool,
}

downloads: struct {
	mutex:         sync.Mutex,
	finished_list: Maybe([]Download),
	list:          []Download,
	version:       int,
	is_scanning:   bool,
	scanned_index: int,
	scanned_visit: int,
}

// Music.app keeps each downloaded Apple Music song as a package of its own, two folders down.
@(private = "file")
read_download_folder_path :: proc() -> string {
	return fmt.tprintf(
		"%s/Music/Music/Media.localized/Apple Music",
		os.get_env("HOME", context.temp_allocator),
	)
}

// The file name holds the catalog ID after CATALOG_ID_MARKER. It ends in "_alac" when lossless.
@(private = "file")
CATALOG_ID_MARKER :: "_A"

@(private = "file")
read_download :: proc(boot_path: string) -> (Download, bool) {
	bytes, error := os.read_entire_file(boot_path, context.temp_allocator)
	if error != nil do return {}, false

	boot := string(bytes)
	if !strings.contains(boot, "<Complete>YES</Complete>") do return {}, false

	start := strings.index(boot, CATALOG_ID_MARKER)

	for start >= 0 {
		rest := boot[start + len(CATALOG_ID_MARKER):]
		digit_count := strings.index_proc(rest, proc(character: rune) -> bool {
			return character < '0' || character > '9'
		})

		if digit_count > 0 && strings.has_prefix(rest[digit_count:], "_audio_") {
			stream_end := strings.index(rest, ".m3u8\"")
			is_lossless := stream_end > 0 && strings.has_suffix(rest[:stream_end], "_alac")

			return {strings.clone(rest[:digit_count]), is_lossless}, true
		}

		next := strings.index(rest, CATALOG_ID_MARKER)
		start = start + len(CATALOG_ID_MARKER) + next if next >= 0 else -1
	}

	return {}, false
}

@(private = "file")
scan_downloads :: proc() {
	found := make([dynamic]Download)
	artists, _ := os.read_all_directory_by_path(
		read_download_folder_path(),
		context.temp_allocator,
	)

	for artist in artists {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		albums, _ := os.read_all_directory_by_path(artist.fullpath, context.temp_allocator)

		for album in albums {
			songs, _ := os.read_all_directory_by_path(album.fullpath, context.temp_allocator)

			for song in songs {
				if !strings.has_suffix(song.name, ".movpkg") do continue

				if download, ok := read_download(fmt.tprintf("%s/boot.xml", song.fullpath)); ok {
					append(&found, download)
				}
			}
		}
	}

	sync.guard(&downloads.mutex)
	downloads.finished_list = found[:]
	downloads.version += 1
	downloads.is_scanning = false
	platform.wake()
}

build_downloaded_page :: proc() {
	list: []Download
	scan_version: int

	{
		sync.guard(&downloads.mutex)

		is_new_visit :=
			downloads.scanned_index != core.navigation.index ||
			downloads.scanned_visit != core.navigation_visit

		should_scan := !downloads.is_scanning && (downloads.version == 0 || is_new_visit)

		if should_scan {
			downloads.scanned_index = core.navigation.index
			downloads.scanned_visit = core.navigation_visit
			downloads.is_scanning = true
			thread.create_and_start(scan_downloads, self_cleanup = true)
		}

		if finished, ok := downloads.finished_list.?; ok {
			for download in downloads.list do delete(download.catalog_id)
			delete(downloads.list)
			downloads.list = finished
			downloads.finished_list = nil
		}

		list = downloads.list
		scan_version = downloads.version
	}

	if scan_version == 0 {
		lists.build_song_list_page("Downloaded", "", nil, .Loading)
		return
	}

	signature := scan_version
	phase := apple.Phase.Ready
	bodies := make([dynamic]string, context.temp_allocator)

	for first := 0; first < len(list); first += MAX_IDS_PER_REQUEST {
		end := min(first + MAX_IDS_PER_REQUEST, len(list))
		ids := make([dynamic]string, context.temp_allocator)
		for download in list[first:end] do append(&ids, download.catalog_id)

		watched := apple.watch(
			fmt.tprintf(
				"/v1/catalog/%s/songs?ids=%s",
				apple.STOREFRONT,
				strings.join(ids[:], ",", context.temp_allocator),
			),
		)

		signature = core.mix_version(signature, watched.version)
		if watched.phase != .Ready do phase = watched.phase
		append(&bodies, watched.body)
	}

	data, needs_read := core.find_page_data("downloaded", signature, phase)

	if needs_read {
		core.read_library_songs(data, bodies[:])

		lossless_count := 0

		for &song in data.songs {
			for download in list {
				if download.catalog_id != song.id do continue
				song.is_lossless = download.is_lossless
				if download.is_lossless do lossless_count += 1
				break
			}
		}

		slice.sort_by(data.songs, proc(a, b: core.Catalog_Song) -> bool {return a.name < b.name})

		data.detail = fmt.aprintf(
			"%d lossless",
			lossless_count,
			allocator = core.page_allocator(data),
		)
	}

	lists.build_song_list_page("Downloaded", data.detail, data.songs, phase)
}

// Apple's songs request takes at most this many IDs.
@(private = "file")
MAX_IDS_PER_REQUEST :: 100
