package menus

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/matching"
import "om:app/playback"
import "om:app/youtube_lists"
import "om:apple"
import "om:platform"
import "om:ui"
import "om:youtube"

SONG_MENU_POINTS :: 220

PLAYLIST_MENU_POINTS :: 240

MAX_PLAYLIST_LIST_POINTS :: 324

PLAYLIST_ITEM_GAP_POINTS :: 1

SUBMENU_GAP_POINTS :: 4

// macOS gives the Escape key the virtual key code 53.
ESCAPE_KEY_CODE :: 53

@(private = "file")
song_menu: struct {
	is_open:           bool,
	song:              core.Catalog_Song,
	position:          [2]f32,
	is_playlists_only: bool,
	is_playlists_open: bool,
	is_naming:         bool,
	opened_frame:      int,
}

@(private = "file")
playlist_name_field: kit.Text_Field

start_song_menu :: proc() {
	playlist_name_field.is_keeping_focus = true
	kit.register_text_field(&playlist_name_field)
}

open_song_menu :: proc(song: core.Catalog_Song, position: [2]f32, is_playlists_only := false) {
	close_song_menu()
	song_menu = {
		is_open           = true,
		song              = core.copy_song(song),
		position          = position,
		is_playlists_only = is_playlists_only,
		is_playlists_open = is_playlists_only,
		opened_frame      = core.app.frame_count,
	}
}

close_song_menu :: proc() {
	if !song_menu.is_open do return

	core.delete_song(song_menu.song)
	song_menu = {}
	playlist_name_field.is_focused = false
	kit.set_field_text(&playlist_name_field, "")
}

build_song_menu :: proc() {
	if !song_menu.is_open do return

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box(
		"menu cover",
		{
			width = ui.fill(),
			height = ui.fill(),
			position = {0, 0},
			flags = {.Floating, .Clickable},
		},
	)
	is_closing :=
		(ui.signal(cover).is_clicked || ui.signal(cover).is_right_clicked) &&
		core.app.frame_count > song_menu.opened_frame + 1

	for event in platform.list_events() {
		if key, ok := event.(platform.Key_Press); ok && key.key_code == ESCAPE_KEY_CODE {
			is_closing = true
		}
	}

	if ui.scope(cover) {
		song := matching.watch_playable(song_menu.song)
		position := song_menu.position
		main_width: f32 = 0

		if !song_menu.is_playlists_only {
			if build_main_menu(song, position, window_size) do is_closing = true
			main_width = SONG_MENU_POINTS + SUBMENU_GAP_POINTS
		}

		if song_menu.is_playlists_open &&
		   build_playlist_menu(song, position + {main_width, 0}, window_size) {
			is_closing = true
		}
	}

	if is_closing do close_song_menu()
}

@(private = "file")
build_main_menu :: proc(song: core.Catalog_Song, position, window_size: [2]f32) -> bool {
	has_id := song.id != ""
	is_from_youtube := youtube.is_song_id(song.id)
	is_playing := is_playing_song(song)
	persistent_id := core.app.now_playing.song.persistent_id if is_playing else ""
	is_favourite := playback.is_favourite(song, persistent_id)
	favourite_label := "Remove from Favourites" if is_favourite else "Favourite"
	favourite_hint := "⌘L" if is_playing else ""
	is_done := false

	menu := kit.menu_box("song menu", position, SONG_MENU_POINTS, window_size)

	if ui.scope(menu) {
		if kit.menu_item("play next", "Play Next") {
			playback.play_next(core.copy_song(song))
			kit.show_toast(fmt.tprintf("%s plays next", song.name))
			is_done = true
		}

		if has_id {
			item := kit.menu_item_signal(
				"add to playlist",
				"Add to Playlist",
				"›",
				song_menu.is_playlists_open,
			)
			if item.is_clicked || item.is_hovered do song_menu.is_playlists_open = true
		}

		if build_youtube_song_items(song) do is_done = true

		kit.menu_separator()

		if kit.menu_item("favourite", favourite_label, favourite_hint) {
			playback.toggle_favourite(song, persistent_id)
			is_done = true
		}

		kit.menu_separator()

		if kit.menu_item("go to artist", "Go to Artist") {
			core.navigate({kind = .Artist, title = strings.clone(song.artist_name)})
			is_done = true
		}

		if has_id && kit.menu_item("copy link", "Copy Link") {
			link: string

			if is_from_youtube {
				link = fmt.tprintf(
					"https://music.youtube.com/watch?v=%s",
					youtube.to_video_id(song.id),
				)
			} else {
				link = fmt.tprintf("https://music.apple.com/%s/song/%s", apple.STOREFRONT, song.id)
			}

			platform.set_clipboard(link)
			kit.show_toast("Copied the link to the song")
			is_done = true
		}
	}

	return is_done
}

@(private = "file")
build_youtube_song_items :: proc(song: core.Catalog_Song) -> bool {
	page := core.current_page()
	is_from_youtube := youtube.is_song_id(song.id)
	is_matched := song.youtube_id != ""
	can_remove :=
		page.kind == .Playlist &&
		is_from_youtube &&
		youtube_lists.is_playlist_youtube_song(page.id, song.id)
	can_try_again := is_from_youtube && matching.is_match_rejected(song)
	is_done := false

	if can_remove && kit.menu_item("remove from playlist", "Remove from Playlist") {
		youtube_lists.remove_playlist_youtube_song(page.id, song.id)
		kit.show_toast(fmt.tprintf("Removed %s from %s", song.name, page.title))
		is_done = true
	}

	if is_matched && kit.menu_item("not on apple music", "Not on Apple Music") {
		matching.reject_match(matching.to_youtube_song(song))
		kit.show_toast(fmt.tprintf("%s plays from YouTube from now on", song.name))
		is_done = true
	}

	if can_try_again && kit.menu_item("try apple music", "Try Apple Music Again") {
		matching.allow_match(song)
		kit.show_toast(fmt.tprintf("Looking for %s on Apple Music again", song.name))
		is_done = true
	}

	return is_done
}

@(private = "file")
build_playlist_menu :: proc(
	song: core.Catalog_Song,
	position: [2]f32,
	window_size: [2]f32,
) -> bool {
	menu := kit.menu_box("playlist menu", position, PLAYLIST_MENU_POINTS, window_size)
	is_done := false

	if ui.scope(menu) {
		if song_menu.is_naming {
			if playlist_name_field.is_cancelled do song_menu.is_naming = false

			name := strings.trim_space(kit.to_field_text(&playlist_name_field))

			if playlist_name_field.is_submitted && name != "" {
				create_playlist_with(name, song)
				is_done = true
			}

			kit.build_text_field(&playlist_name_field, "playlist name", "Playlist name", "", 28)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
					font_size = 11,
					padding = {4, 4, 4, 2},
				},
				"Return makes the playlist. Escape goes back.",
			)
		} else if kit.menu_item("new playlist", "New Playlist…", "", false, core.app.accent) {
			song_menu.is_naming = true
			kit.focus_field(&playlist_name_field)
		}

		kit.menu_separator()

		playlists, _, phase := core.watch_playlists()
		editable_count := 0
		for playlist in playlists do if playlist.can_edit do editable_count += 1

		list_height := min(
			f32(editable_count) * (kit.MENU_ITEM_HEIGHT_POINTS + PLAYLIST_ITEM_GAP_POINTS),
			MAX_PLAYLIST_LIST_POINTS,
		)
		list := ui.box(
			"playlists",
			{
				width = ui.fill(),
				height = ui.points(list_height),
				axis = .Y,
				gap = PLAYLIST_ITEM_GAP_POINTS,
				flags = {.Scroll, .Clip},
			},
		)

		if ui.scope(list) {
			for playlist in playlists {
				if !playlist.can_edit do continue

				if kit.menu_item(fmt.tprintf("playlist %s", playlist.id), playlist.name) {
					add_to_playlist(playlist.id, playlist.name, song)
					is_done = true
				}
			}
		}

		if editable_count == 0 {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
					font_size = 12,
					padding = {8, 4, 8, 4},
				},
				kit.to_phase_text(phase) if phase != .Ready else "No playlists of yours yet.",
			)
		}
	}

	return is_done
}

is_playing_song :: proc(song: core.Catalog_Song) -> bool {
	playing, _, ok := playback.find_playing_song()
	if !ok do return false

	// A song from the queue has its ID. A song Music.app plays without the queue has only its text.
	if playing.id != "" do return matching.is_same_queue_song(playing, song)

	return(
		playing.name == song.name &&
		playing.artist_name == song.artist_name &&
		playing.album_name == song.album_name \
	)
}
