package app

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "om:apple"
import "om:font"
import "om:helper"
import "om:icon"
import "om:image"
import "om:library"
import "om:platform"
import "om:render"
import "om:store"
import "om:ui"

MIN_ZOOM :: 0.5
MAX_ZOOM :: 3.0
ZOOM_STEP :: 0.1
BENCH_POINTS_PER_FRAME :: 30
// The first frames open the window and load fonts, so the bench leaves them out.
BENCH_SKIPPED_FRAME_COUNT :: 10

Panel :: enum {
	None,
	Lyrics,
	Up_Next,
}

app: struct {
	window:            ^platform.Window,
	zoom:              f32,
	albums:            []library.Album,
	songs:             []library.Song,
	// The library songs as the queue takes them.
	queue_songs:       []Catalog_Song,
	playlists:         []library.Playlist,
	accent:            [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	last_frame:        time.Tick,
	// OM_CAPTURE saves a frame to this file and quits, for the development tests. OM_CAPTURE_SECONDS waits first.
	capture_path:      string,
	capture_time:      time.Tick,
	frame_count:       int,
	is_bench:          bool,
	// OM_FRAMES=1 shows how long each frame took to build.
	is_showing_frames: bool,
	bench_frame_count: int,
	bench_direction:   f32,
	build_durations:   [dynamic]time.Duration,
	frame_starts:      [dynamic]time.Tick,
}

main :: proc() {
	app.zoom = 1
	app.accent = DEFAULT_ACCENT
	app.panel = .Lyrics
	app.capture_path = os.get_env("OM_CAPTURE", context.allocator)
	app.is_bench = os.get_env("OM_BENCH", context.temp_allocator) == "1"
	app.bench_frame_count = strconv.parse_int(os.get_env("OM_BENCH_FRAMES", context.temp_allocator)) or_else 1200
	app.bench_direction = 1
	app.is_showing_frames = os.get_env("OM_FRAMES", context.temp_allocator) == "1"
	capture_seconds := strconv.parse_f64(os.get_env("OM_CAPTURE_SECONDS", context.temp_allocator)) or_else 0
	app.capture_time = time.tick_add(time.tick_now(), time.Duration(capture_seconds * f64(time.Second)))

	store.start()
	apple.start()
	app.albums = library.list_albums()
	app.songs = library.list_songs()
	app.playlists = library.list_playlists()
	app.queue_songs = to_catalog_songs(app.songs)
	start_queue()
	navigate({kind = .Albums})
	start_lyrics()

	// A test or bench run opens behind the other windows and leaves Music.app as it is when it quits.
	is_background := app.capture_path != "" || app.is_bench || os.get_env("OM_BACKGROUND", context.temp_allocator) == "1"
	helper.start(is_background)

	app.window = platform.open_window("onlymuse", {1200, 800}, draw_frame, is_background)
	render.start(app.window.device, app.window.layer)
	font.start()
	icon.start()
	image.start()
	app.last_frame = time.tick_now()
	platform.run()
}

apply_helper_messages :: proc() {
	for message in helper.take_messages() {
		helper.apply(&app.now_playing, message)

		switch message.type {
		case "accent":
			app.accent = to_color_from_hex(message.color)
		case "tokens":
			apple.set_tokens(message.developer_token, message.user_token)
		case "error":
			// Music.app has no current track while stopped, and the helper's next post says so.
			if !strings.contains(message.text, "get current track") do fmt.eprintfln("helper: %s", message.text)
		case "playSongResult", "setNextResult":
			apply_queue_answer(message.request_id, message.persistent_id)
		case "nowPlaying":
			apply_queue_now_playing()
		}
	}
}

apply_keys :: proc() {
	for event in platform.list_events() {
		key, ok := event.(platform.Key_Press)
		if !ok || .Command not_in key.modifiers do continue

		apply_lead_key(key)

		switch key.characters {
		case "=", "+":
			app.zoom = min(app.zoom + ZOOM_STEP, MAX_ZOOM)
		case "-":
			app.zoom = max(app.zoom - ZOOM_STEP, MIN_ZOOM)
		case "0":
			app.zoom = 1
		case "q":
			platform.quit()
		}
	}
}

// A library song plays by its catalog ID, which Music.app's library songs also carry.
to_catalog_songs :: proc(songs: []library.Song) -> []Catalog_Song {
	catalog_songs := make([]Catalog_Song, len(songs))

	for song, index in songs {
		id := song.catalog_id if song.catalog_id != "" else song.id
		catalog_songs[index] = {id = id, name = song.name, artist_name = song.artist_name, album_name = song.album_name, duration_seconds = song.duration_seconds}
		catalog_songs[index].artwork.url = song.artwork_url
	}

	return catalog_songs
}

toggle_panel :: proc(panel: Panel) {
	app.panel = .None if app.panel == panel else panel
}

draw_frame :: proc() -> bool {
	free_all(context.temp_allocator)
	start := time.tick_now()
	dt_seconds := f32(time.duration_seconds(time.tick_diff(app.last_frame, start)))
	app.last_frame = start
	append(&app.frame_starts, start)
	apply_helper_messages()
	update_queue()
	apply_keys()

	window := app.window
	size_pixels := window.size_points * window.pixels_per_point

	render.begin_frame(size_pixels)
	font.begin_frame()
	image.begin_frame()
	ui.begin_frame(window.size_points, window.pixels_per_point, app.zoom, dt_seconds)

	root := ui.current_parent()
	root.style.axis = .Y
	root.style.background = colors.window
	is_lyrics_moving := false

	top := ui.box("top", {width = ui.fill(), height = ui.fill(), axis = .X})

	if ui.scope(top) {
		build_sidebar()
		build_page_area()
		is_lyrics_moving = build_panel()
	}

	build_player_bar()
	build_frame_time()
	ui.end_frame()

	app.frame_count += 1
	is_capture_frame := app.capture_path != "" && app.frame_count >= 3 && time.tick_diff(app.capture_time, start) >= 0
	if is_capture_frame do render.request_capture(app.capture_path)
	append(&app.build_durations, time.tick_since(start))
	render.end_frame(window.drawable)
	if is_capture_frame do platform.quit()
	if app.is_bench && app.frame_count == app.bench_frame_count do finish_bench()

	return app.capture_path != "" || app.is_bench || ui.is_animating() || font.is_redraw_needed() || image.is_animating() || is_lyrics_moving
}

build_frame_time :: proc() {
	count := len(app.build_durations)
	if count == 0 || !app.is_showing_frames do return

	last := time.duration_milliseconds(app.build_durations[count - 1])
	root := ui.current_parent()
	ui.box("", {
		width      = ui.points(110),
		height     = ui.points(20),
		position   = {root.style.width.value - 120, 8},
		text_align = .End,
		text_color = colors.faint,
		font_size  = 11,
		flags      = {.Floating},
	}, fmt.tprintf("frame %.2f ms", last))
}

run_bench_scroll :: proc(list: ^ui.Box) {
	if !app.is_bench do return

	max_scroll := list.content_size.y - list.size.y

	if max_scroll <= 0 do return
	if list.scroll >= max_scroll || (list.scroll <= 0 && app.bench_direction < 0) do app.bench_direction *= -1

	ui.set_scroll(list, list.scroll + BENCH_POINTS_PER_FRAME * app.bench_direction)
}

finish_bench :: proc() {
	remove_range(&app.build_durations, 0, BENCH_SKIPPED_FRAME_COUNT)
	remove_range(&app.frame_starts, 0, BENCH_SKIPPED_FRAME_COUNT)

	builds := app.build_durations[:]
	slice.sort(builds)
	gaps: [dynamic]time.Duration
	for index in 1 ..< len(app.frame_starts) do append(&gaps, time.tick_diff(app.frame_starts[index - 1], app.frame_starts[index]))
	slice.sort(gaps[:])

	to_ms :: proc(values: []time.Duration, fraction: f64) -> f64 {
		return time.duration_milliseconds(values[int(math.floor(f64(len(values) - 1) * fraction))])
	}
	fmt.printfln("build per frame ms: p50 %.2f p99 %.2f max %.2f", to_ms(builds, 0.5), to_ms(builds, 0.99), to_ms(builds, 1))
	ready, total := image.count()
	fmt.printfln("covers on the GPU %d, known %d", ready, total)
	fmt.printfln("gap between frames ms: p50 %.2f p99 %.2f max %.2f", to_ms(gaps[:], 0.5), to_ms(gaps[:], 0.99), to_ms(gaps[:], 1))
	platform.quit()
}
