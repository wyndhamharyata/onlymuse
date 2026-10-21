package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "om:apple"
import "om:platform"
import "om:ui"
import "om:youtube"

SONG_MENU_POINTS :: 220
PLAYLIST_MENU_POINTS :: 240
MENU_ITEM_POINTS :: 26
MAX_PLAYLIST_LIST_POINTS :: 324
ESCAPE_KEY_CODE :: 53
// A press that moves this far becomes a drag.
DRAG_START_POINTS :: 6

@(private = "file")
song_menu: struct {
	is_open:          bool,
	song:             Catalog_Song,
	position:         [2]f32,
	// Opened from Add to Playlist, it shows the playlists alone.
	is_playlists_only: bool,
	is_playlists_open: bool,
	is_naming:        bool,
	opened_frame:     int,
}

@(private = "file")
playlist_name_field: Text_Field

start_song_menu :: proc() {
	playlist_name_field.keeps_focus = true
	register_text_field(&playlist_name_field)
}

// Right-click on a song, or Now Playing's Add to Playlist. position is in window points.
open_song_menu :: proc(song: Catalog_Song, position: [2]f32, is_playlists_only := false) {
	close_song_menu()
	song_menu = {
		is_open           = true,
		song              = clone_song(song),
		position          = position,
		is_playlists_only = is_playlists_only,
		is_playlists_open = is_playlists_only,
		opened_frame      = app.frame_count,
	}
}

close_song_menu :: proc() {
	if !song_menu.is_open do return

	delete_song(song_menu.song)
	song_menu = {}
	playlist_name_field.is_focused = false
	set_field_text(&playlist_name_field, "")
}

clone_song :: proc(song: Catalog_Song) -> Catalog_Song {
	cloned := song
	cloned.id = strings.clone(song.id)
	cloned.name = strings.clone(song.name)
	cloned.artist_name = strings.clone(song.artist_name)
	cloned.album_name = strings.clone(song.album_name)
	cloned.youtube_id = strings.clone(song.youtube_id)
	cloned.artwork.url = strings.clone(song.artwork.url)
	cloned.artwork.bg_color = strings.clone(song.artwork.bg_color)
	cloned.artwork.text_color1 = strings.clone(song.artwork.text_color1)

	return cloned
}

delete_song :: proc(song: Catalog_Song) {
	delete(song.id)
	delete(song.name)
	delete(song.artist_name)
	delete(song.album_name)
	delete(song.youtube_id)
	delete(song.artwork.url)
	delete(song.artwork.bg_color)
	delete(song.artwork.text_color1)
}

// Over everything, with a cover that closes it on a click outside.
build_song_menu :: proc() {
	if !song_menu.is_open do return

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box("menu cover", {width = ui.fill(), height = ui.fill(), position = {0, 0}, flags = {.Floating, .Clickable}})
	is_closing := (ui.signal(cover).is_clicked || ui.signal(cover).is_right_clicked) && app.frame_count > song_menu.opened_frame + 1

	// Escape closes it, unless the playlist name field takes it.
	for event in platform.list_events() {
		if key, ok := event.(platform.Key_Press); ok && key.key_code == ESCAPE_KEY_CODE do is_closing = true
	}

	if ui.scope(cover) {
		// A YouTube song Apple has acts as Apple's song.
		song := to_playable(song_menu.song)
		is_from_youtube := youtube.is_song_id(song.id)
		is_matched := song.youtube_id != ""
		page := current_page()
		position := song_menu.position
		main_width: f32 = 0

		if !song_menu.is_playlists_only {
			menu := menu_box("song menu", position, SONG_MENU_POINTS, window_size)
			main_width = SONG_MENU_POINTS + 4

			if ui.scope(menu) {
				if menu_item("play next", "Play Next") {
					// The queue keeps the song after the menu frees its own copy.
					play_next(clone_song(song))
					show_toast(fmt.tprintf("%s plays next", song.name))
					is_closing = true
				}

				if song.id != "" {
					item := menu_item_signal("add to playlist", "Add to Playlist", "›", song_menu.is_playlists_open)
					if item.is_clicked || item.is_hovered do song_menu.is_playlists_open = true
				}

				if page.kind == .Playlist && is_from_youtube && is_playlist_youtube_song(page.id, song.id) && menu_item("remove from playlist", "Remove from Playlist") {
					remove_playlist_youtube_song(page.id, song.id)
					show_toast(fmt.tprintf("Removed %s from %s", song.name, page.title))
					is_closing = true
				}

				if is_matched && menu_item("not on apple music", "Not on Apple Music") {
					reject_match(to_youtube_song(song))
					show_toast(fmt.tprintf("%s plays from YouTube from now on", song.name))
					is_closing = true
				}
				if is_from_youtube && is_match_rejected(song) && menu_item("try apple music", "Try Apple Music Again") {
					allow_match(song)
					show_toast(fmt.tprintf("Looking for %s on Apple Music again", song.name))
					is_closing = true
				}

				menu_separator()
				is_on := is_favourite(song)
				if menu_item("favourite", "Remove from Favourites" if is_on else "Favourite", "⌘L" if is_playing_song(song) else "") {
					toggle_favourite(song, app.now_playing.song.persistent_id if is_playing_song(song) else "")
					is_closing = true
				}

				menu_separator()
				if menu_item("go to artist", "Go to Artist") {
					navigate({kind = .Artist, title = strings.clone(song.artist_name)})
					is_closing = true
				}
				if song.id != "" && menu_item("copy link", "Copy Link") {
					apple_link := fmt.tprintf("https://music.apple.com/%s/song/%s", apple.STOREFRONT, song.id)
					platform.write_clipboard(fmt.tprintf("https://music.youtube.com/watch?v=%s", youtube.to_video_id(song.id)) if is_from_youtube else apple_link)
					show_toast("Copied the link to the song")
					is_closing = true
				}
			}
		}

		if song_menu.is_playlists_open && build_playlist_menu(song, position + {main_width, 0}, window_size) do is_closing = true
	}

	if is_closing do close_song_menu()
}

// Returns true when a playlist was picked or made.
@(private = "file")
build_playlist_menu :: proc(song: Catalog_Song, position: [2]f32, window_size: [2]f32) -> bool {
	menu := menu_box("playlist menu", position, PLAYLIST_MENU_POINTS, window_size)
	is_done := false

	if ui.scope(menu) {
		if song_menu.is_naming {
			if playlist_name_field.is_cancelled do song_menu.is_naming = false

			name := strings.trim_space(field_text(&playlist_name_field))
			if playlist_name_field.is_submitted && name != "" {
				create_playlist_with(name, song)
				is_done = true
			}

			build_text_field(&playlist_name_field, "playlist name", "Playlist name", "", 28)
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 11, padding = {4, 4, 4, 2}}, "Return makes it, Escape goes back.")
		} else if menu_item("new playlist", "New Playlist…", "", false, app.accent) {
			song_menu.is_naming = true
			focus_field(&playlist_name_field)
		}

		menu_separator()

		playlists, _, phase := list_playlists()
		editable := 0
		for playlist in playlists do if playlist.can_edit do editable += 1

		// A long list scrolls inside the menu.
		list_height := min(f32(editable) * (MENU_ITEM_POINTS + 1), MAX_PLAYLIST_LIST_POINTS)
		list := ui.box("playlists", {width = ui.fill(), height = ui.points(list_height), axis = .Y, gap = 1, flags = {.Scroll, .Clip}})
		shown := 0

		if ui.scope(list) {
			for playlist in playlists {
				if !playlist.can_edit do continue

				shown += 1
				if menu_item(fmt.tprintf("playlist %s", playlist.id), playlist.name) {
					add_to_playlist(playlist.id, playlist.name, song)
					is_done = true
				}
			}
		}

		if shown == 0 do ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = colors.faint, font_size = 12, padding = {8, 4, 8, 4}}, phase_note(phase) if phase != .Ready else "No playlists of yours yet.")
	}

	return is_done
}

@(private = "file")
is_playing_song :: proc(song: Catalog_Song) -> bool {
	playing, _, ok := find_playing_song()

	return ok && playing.name == song.name && playing.artist_name == song.artist_name
}

// A menu's panel, kept inside the window.
menu_box :: proc(id: string, position: [2]f32, width: f32, window_size: [2]f32) -> ^ui.Box {
	existing := ui.find_box(id, ui.current_parent())
	height: f32 = existing.size.y if existing != nil else 200
	x := clamp(position.x, 8, window_size.x - width - 8)
	y := clamp(position.y, 8, max(8, window_size.y - height - 8))

	ui.box(fmt.tprintf("%s shadow", id), {width = ui.points(width), height = ui.points(height), corner_radius = 12, background = {0, 0, 0, 0.45}, softness = 24, position = {x, y + 8}, flags = {.Floating}})

	return ui.box(id, {
		width         = ui.points(width),
		height        = ui.fit_children(),
		axis          = .Y,
		gap           = 1,
		padding       = {5, 5, 5, 5},
		corner_radius = 10,
		background    = to_color(0x2c2c31f5),
		border_width  = 1,
		border_color  = to_color(0xffffff1c),
		position      = {x, y},
		flags         = {.Floating, .Clickable},
	})
}

// A selected item, such as the open submenu's, takes the accent.
menu_item_signal :: proc(id, label: string, hint := "", is_selected := false, color := [4]f32{}) -> ui.Signal {
	item := ui.box(id, {
		width            = ui.fill(),
		height           = ui.points(MENU_ITEM_POINTS),
		axis             = .X,
		align            = .Center,
		padding          = {9, 0, 9, 0},
		corner_radius    = 6,
		background       = app.accent if is_selected else {},
		hover_background = app.accent,
		flags            = {.Clickable},
	})
	text_color := color if color.a > 0 else colors.text
	if is_selected || item.hot_t > 0.5 do text_color = to_color(0xffffffff)

	if ui.scope(item) {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = text_color, font_size = 13, flags = {.Truncate_Text}}, label)
		if hint != "" do ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = text_color if is_selected else colors.faint, font_size = 12}, hint)
	}

	return ui.signal(item)
}

menu_item :: proc(id, label: string, hint := "", is_selected := false, color := [4]f32{}) -> bool {
	return menu_item_signal(id, label, hint, is_selected, color).is_clicked
}

menu_separator :: proc() {
	ui.box("", {width = ui.fill(), height = ui.points(1), background = to_color(0xffffff14)})
}

// ---- Writes to Apple ----

@(private = "file")
Write_Job :: struct {
	path, body:            string,
	done_text, failed_text: string,
	// Asked again once the write is done, so the page shows it.
	refresh_path:          string,
}

@(private = "file")
Created_Playlist :: struct {
	id, name, done_text: string,
	youtube_songs:       []Playlist_YouTube_Song,
	opens_page:          bool,
}

@(private = "file")
write_results: struct {
	mutex:   sync.Mutex,
	toasts:  [dynamic]string,
	refresh: [dynamic]string,
	created: [dynamic]Created_Playlist,
}

@(private = "file")
start_write :: proc(job: Write_Job) {
	copied := new(Write_Job)
	copied^ = {strings.clone(job.path), strings.clone(job.body), strings.clone(job.done_text), strings.clone(job.failed_text), strings.clone(job.refresh_path)}
	thread.create_and_start_with_data(copied, run_write, self_cleanup = true)
}

// Runs on a thread of its own, as the request blocks.
@(private = "file")
run_write :: proc(data: rawptr) {
	job := cast(^Write_Job)data
	status := apple.post(job.path, job.body).status
	is_done := status >= 200 && status < 300

	{
		sync.guard(&write_results.mutex)
		failed := fmt.aprintf("%s: no answer from Apple.", job.failed_text) if status == 0 else fmt.aprintf("%s: Apple answered %d.", job.failed_text, status)
		append(&write_results.toasts, strings.clone(job.done_text) if is_done else failed)
		if is_done do delete(failed)
		if is_done && job.refresh_path != "" do append(&write_results.refresh, strings.clone(job.refresh_path))
	}
	platform.wake()

	delete(job.path)
	delete(job.body)
	delete(job.done_text)
	delete(job.failed_text)
	delete(job.refresh_path)
	free(job)
	free_all(context.temp_allocator)
}

// Once a frame: the notes and refreshes of finished writes.
apply_write_results :: proc() {
	sync.guard(&write_results.mutex)

	for text in write_results.toasts {
		show_toast(text)
		delete(text)
	}
	for path in write_results.refresh {
		apple.refresh(path)
		delete(path)
	}
	for created in write_results.created {
		if len(created.youtube_songs) > 0 do add_playlist_youtube_songs(created.id, created.youtube_songs)
		show_toast(created.done_text)
		apple.refresh(PLAYLISTS_PATH)
		if created.opens_page do navigate({kind = .Playlist, id = created.id, title = created.name})
	}
	clear(&write_results.toasts)
	clear(&write_results.refresh)
	clear(&write_results.created)
}

@(private = "file")
Song_Reference :: struct {
	id:   string,
	type: string,
}

// A song only on YouTube stays in onlymuse's part of the playlist, as Apple's playlists hold Apple songs alone.
add_to_playlist :: proc(playlist_id, playlist_name: string, chosen: Catalog_Song) {
	song := to_playable(chosen)

	if youtube.is_song_id(song.id) {
		add_playlist_youtube_songs(playlist_id, {{"", song}})
		show_toast(fmt.tprintf("Added %s to %s. It plays from YouTube.", song.name, playlist_name))
		return
	}

	Body :: struct {
		data: []Song_Reference,
	}
	body, _ := json.marshal(Body{{{song.id, "songs"}}}, allocator = context.temp_allocator)

	start_write({
		path         = fmt.tprintf("/v1/me/library/playlists/%s/tracks", playlist_id),
		body         = string(body),
		done_text    = fmt.tprintf("Added %s to %s", song.name, playlist_name),
		failed_text  = fmt.tprintf("Could not add %s to %s", song.name, playlist_name),
		refresh_path = fmt.tprintf("/v1/me/library/playlists/%s/tracks?limit=100&offset=0", playlist_id),
	})
}

@(private = "file")
create_playlist_with :: proc(name: string, chosen: Catalog_Song) {
	song := to_playable(chosen)
	done_text := fmt.tprintf("Made %s with %s", name, song.name)

	if youtube.is_song_id(song.id) {
		create_playlist(name, nil, {{"", song}}, done_text)
		return
	}

	create_playlist(name, {song}, nil, done_text)
}

PLAYLISTS_PATH :: "/v1/me/library/playlists?limit=100"

@(private = "file")
Create_Job :: struct {
	name, body, done_text: string,
	youtube_songs:         []Playlist_YouTube_Song,
	opens_page:            bool,
}

// A new library playlist of Apple songs, with songs only on YouTube kept beside it once Apple gives its ID.
create_playlist :: proc(name: string, songs: []Catalog_Song, youtube_songs: []Playlist_YouTube_Song, done_text: string, opens_page := false) {
	Body :: struct {
		attributes:    struct {
			name: string,
		},
		relationships: struct {
			tracks: struct {
				data: []Song_Reference,
			},
		},
	}
	value: Body
	value.attributes.name = name
	references := make([]Song_Reference, len(songs), context.temp_allocator)
	for song, index in songs do references[index] = {song.id, "songs"}
	value.relationships.tracks.data = references
	body, _ := json.marshal(value, allocator = context.temp_allocator)

	kept := make([]Playlist_YouTube_Song, len(youtube_songs))
	for song, index in youtube_songs do kept[index] = {strings.clone(song.after), clone_song(song.song)}

	job := new(Create_Job)
	job^ = {strings.clone(name), strings.clone(string(body)), strings.clone(done_text), kept, opens_page}
	thread.create_and_start_with_data(job, run_create, self_cleanup = true)
}

// Runs on a thread of its own. The created playlist reaches the main thread through write_results.
@(private = "file")
run_create :: proc(data: rawptr) {
	job := cast(^Create_Job)data
	defer free_all(context.temp_allocator)
	defer free(job)
	defer delete(job.body)

	answer := apple.post("/v1/me/library/playlists", job.body)
	resources := apple.to_resources(answer.body, context.temp_allocator) if answer.status >= 200 && answer.status < 300 else nil

	sync.guard(&write_results.mutex)
	defer platform.wake()

	if len(resources) == 0 {
		append(&write_results.toasts, fmt.aprintf("Could not make %s: Apple answered %d.", job.name, answer.status))
		delete(job.name)
		delete(job.done_text)
		return
	}

	append(&write_results.created, Created_Playlist{strings.clone(resources[0].id), job.name, job.done_text, job.youtube_songs, job.opens_page})
}

// ---- Dragging a song onto a playlist ----

@(private = "file")
drag: struct {
	is_dragging: bool,
	song:        Catalog_Song,
	// The frame a drag ended, so the row under the release does not take it as a click.
	ended_frame: int,
}

// A row reports its signal each frame. Returns true when the row was clicked, and not dragged.
track_song_row :: proc(signal: ui.Signal, song: Catalog_Song) -> bool {
	if signal.is_right_clicked do open_song_menu(song, ui.mouse_position())

	press, is_down := ui.press_position()
	moved := ui.mouse_position() - press
	if signal.is_held && is_down && !drag.is_dragging && moved.x * moved.x + moved.y * moved.y > DRAG_START_POINTS * DRAG_START_POINTS && song.id != "" {
		drag = {is_dragging = true, song = clone_song(song)}
	}

	return signal.is_clicked && drag.ended_frame != app.frame_count
}

is_dragging_song :: proc() -> bool {
	return drag.is_dragging
}

// A sidebar playlist under a dragged song lights up, and takes it on release.
take_song_drop :: proc(is_hovered: bool, playlist_id, playlist_name: string, can_edit: bool) -> bool {
	if !drag.is_dragging || !is_hovered || !can_edit do return false

	if is_mouse_released() do add_to_playlist(playlist_id, playlist_name, drag.song)

	return true
}

@(private = "file")
is_mouse_released :: proc() -> bool {
	for event in platform.list_events() {
		if release, ok := event.(platform.Mouse_Release); ok && release.button == .Left do return true
	}

	return false
}

// The song's name follows the pointer while it is dragged.
build_drag_ghost :: proc() {
	if !drag.is_dragging do return

	if is_mouse_released() {
		delete_song(drag.song)
		drag = {ended_frame = app.frame_count}
		return
	}

	mouse := ui.mouse_position()
	ghost := ui.box("drag ghost", {
		width         = ui.fit_children(),
		height        = ui.points(30),
		axis          = .X,
		align         = .Center,
		gap           = 7,
		padding       = {10, 0, 12, 0},
		corner_radius = 8,
		background    = to_color(0x2c2c31f0),
		border_width  = 1,
		border_color  = {app.accent.r, app.accent.g, app.accent.b, 0.6},
		position      = mouse + {12, 8},
		flags         = {.Floating},
	})

	if ui.scope(ghost) {
		icon_box("", "music.note", 12, app.accent)
		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = colors.text, font_size = 12.5}, drag.song.name)
	}
	platform.request_frame()
}
