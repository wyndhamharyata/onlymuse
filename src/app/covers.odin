package main

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "om:console"
import "om:net"

covers_folder: string

start_covers :: proc() {
	home := os.get_env("HOME", context.temp_allocator)
	covers_folder, _ = filepath.join(
		{home, "Library", "Caches", "onlymuse-native", "images"},
		context.allocator,
	)
	os.make_directory_all(covers_folder)

	net.start()
}

fetch_cover :: proc(url: string) -> (path: string, ok: bool) {
	path = fmt.tprintf("%s/%x.jpg", covers_folder, hash.fnv64a(transmute([]u8)url))
	if os.exists(path) do return path, true

	response := net.fetch(url)

	if response.status != 200 {
		console.add("Covers", "%s: %s", url, console.to_status_text(response.status))
		return "", false
	}
	if !strings.has_prefix(response.content_type, "image/") do return "", false

	part_path := fmt.tprintf("%s.part", path)
	if os.write_entire_file(part_path, response.body) != nil do return "", false
	if os.rename(part_path, path) != nil do return "", false

	return path, true
}
