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
	mutex:       sync.Mutex,
	list:        []Download,
	// Counts up with each finished scan.
	version:     int,
	is_scanning: bool,
	// The visit that started the last scan.
	scanned_index: int,
	scanned_visit: int,
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
		// Frees this artist's temp memory when the pass ends, and keeps artists.
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
	downloads.list = found[:]
	downloads.version += 1
	downloads.is_scanning = false
	platform.wake()
}

// The quality comes from the file Music.app saved, not from what Apple offers.
build_downloaded_page :: proc() {
	list: []Download
	scan_version: int
	// sync.guard unlocks when its block ends, so these braces end the lock.
	{
		sync.guard(&downloads.mutex)
		// Each visit scans again, so a song downloaded since shows.
		is_new_visit := downloads.scanned_index != core.navigation.index || downloads.scanned_visit != core.navigation_visit
		if !downloads.is_scanning && (downloads.version == 0 || is_new_visit) {
			downloads.scanned_index = core.navigation.index
			downloads.scanned_visit = core.navigation_visit
			downloads.is_scanning = true
			// self_cleanup frees the thread when its procedure returns, so nothing waits for it.
			thread.create_and_start(scan_downloads, self_cleanup = true)
		}
		list = downloads.list
		scan_version = downloads.version
	}

	if scan_version == 0 {
		lists.build_song_list_page("Downloaded", "", nil, .Loading)
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

	data, is_stale := core.find_page_data("downloaded", signature, phase)

	if is_stale && phase == .Ready {
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
		data.detail = fmt.aprintf("%d lossless", lossless_count, allocator = core.page_allocator(data))
	}

	lists.build_song_list_page("Downloaded", data.detail, data.songs, phase)
}

TOP_RESULT_POINTS :: 180
