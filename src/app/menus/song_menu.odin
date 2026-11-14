package menus

import "core:fmt"
import "core:strings"
import "om:app/core"
import "om:app/look"
import "om:app/matching"
import "om:app/playback"
import "om:app/youtube_lists"
import "om:apple"
import "om:youtube"
import "thor:kit"
import "thor:platform"
import "thor:ui"

SONG_MENU_WIDTH :: 220

PLAYLIST_MENU_WIDTH :: 240

MAX_PLAYLIST_LIST_HEIGHT :: 324

PLAYLIST_ITEM_GAP :: 1

// A song's menu: the context menu at a point, or the playlist menu by Now Playing's button.
@(private = "file")
Song_Menu :: struct {
	is_open:  bool,
	has_song: bool,
	song:     core.Catalog_Song,
	pos:      [2]f32,
	is_built: bool,
}

@(private = "file")
song_menu: Song_Menu

@(private = "file")
playlist_menu: Song_Menu

// Whether the playlist name field shows in place of New Playlist…, in either menu.
@(private = "file")
is_naming: bool

@(private = "file")
playlist_name_field: kit.Text_Input

start_song_menu :: proc() {
	playlist_name_field.is_keeping_focus = true
}

// Opens the song's context menu at pos, the point that was right-clicked.
open_song_menu :: proc(song: core.Catalog_Song, pos: [2]f32) {
	close_menu(&song_menu)
	song_menu = {
		is_open  = true,
		has_song = true,
		song     = core.copy_song(song),
		pos      = pos,
	}
}

// Opens the song's playlist menu, or closes it when it is open: the action of Now Playing's button.
toggle_playlist_menu :: proc(song: core.Catalog_Song) {
	if playlist_menu.is_open {
		playlist_menu.is_open = false
		return
	}

	close_menu(&playlist_menu)
	playlist_menu = {
		is_open  = true,
		has_song = true,
		song     = core.copy_song(song),
	}
}

// Builds the playlist menu by anchor, the button that toggles it. Call it right after the button.
build_playlist_menu :: proc(anchor: ^ui.Box) {
	playlist_menu.is_built = true
	is_done := false

	if kit.menu("playlist_menu", &playlist_menu.is_open, anchor, width = ui.points(PLAYLIST_MENU_WIDTH)) {
		is_done = build_playlist_items(matching.watch_playable(playlist_menu.song))
	}

	if is_done do playlist_menu.is_open = false
}

// Builds the context menu, after the page. It also lets go of a menu that closed, or whose button is gone.
build_song_menu :: proc() {
	is_done := false

	if kit.menu("song_menu", &song_menu.is_open, song_menu.pos, width = ui.points(SONG_MENU_WIDTH)) {
		is_done = build_main_menu(matching.watch_playable(song_menu.song))
	}

	if is_done do song_menu.is_open = false
	if !playlist_menu.is_built do playlist_menu.is_open = false
	playlist_menu.is_built = false

	for menu in ([]^Song_Menu{&song_menu, &playlist_menu}) {
		if !menu.is_open do close_menu(menu)
	}
}

@(private = "file")
close_menu :: proc(menu: ^Song_Menu) {
	if !menu.has_song do return

	core.delete_song(menu.song)
	menu^ = {}
	is_naming = false
	playlist_name_field.is_focused = false
	kit.set_input_text(&playlist_name_field, "")
}

@(private = "file")
build_main_menu :: proc(song: core.Catalog_Song) -> bool {
	has_id := song.id != ""
	is_from_youtube := youtube.is_song_id(song.id)
	is_playing := is_playing_song(song)
	persistent_id := core.app.now_playing.song.persistent_id if is_playing else ""
	is_favourite := playback.is_favourite(song, persistent_id)
	favourite_label := "Remove from Favourites" if is_favourite else "Favourite"
	favourite_hint := "⌘L" if is_playing else ""
	is_done := false

	if kit.menu_item("play_next", "Play Next").is_activated {
		playback.play_next(core.copy_song(song))
		kit.show_toast(fmt.tprintf("%s plays next", song.name))
		is_done = true
	}

	if has_id {
		if kit.submenu("add_to_playlist", "Add to Playlist", ui.points(PLAYLIST_MENU_WIDTH)) {
			if build_playlist_items(song) do is_done = true
		}
	}

	if build_youtube_song_items(song) do is_done = true

	kit.menu_separator()

	if playback.can_favourite(song) {
		if kit.menu_item("favourite", favourite_label, favourite_hint).is_activated {
			playback.toggle_favourite(song, persistent_id)
			is_done = true
		}

		kit.menu_separator()
	}

	if kit.menu_item("go_to_artist", "Go to Artist").is_activated {
		core.navigate({kind = .Artist, title = strings.clone(song.artist_name)})
		is_done = true
	}

	if has_id && kit.menu_item("copy_link", "Copy Link").is_activated {
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

	if can_remove && kit.menu_item("remove_from_playlist", "Remove from Playlist").is_activated {
		youtube_lists.remove_playlist_youtube_song(page.id, song.id)
		kit.show_toast(fmt.tprintf("Removed %s from %s", song.name, page.title))
		is_done = true
	}

	if is_matched && kit.menu_item("not_on_apple_music", "Not on Apple Music").is_activated {
		matching.reject_match(matching.to_youtube_song(song))
		kit.show_toast(fmt.tprintf("%s plays from YouTube from now on", song.name))
		is_done = true
	}

	if can_try_again && kit.menu_item("try_apple_music", "Try Apple Music Again").is_activated {
		matching.allow_match(song)
		kit.show_toast(fmt.tprintf("Looking for %s on Apple Music again", song.name))
		is_done = true
	}

	return is_done
}

@(private = "file")
build_playlist_items :: proc(song: core.Catalog_Song) -> bool {
	is_done := false

	if is_naming {
		if playlist_name_field.is_cancelled do is_naming = false

		name := strings.trim_space(kit.to_input_text(&playlist_name_field))

		if playlist_name_field.is_submitted && name != "" {
			create_playlist_with(name, song)
			is_done = true
		}

		kit.text_field(
			"playlist_name",
			&playlist_name_field,
			"Playlist name",
			style = {height = ui.points(28)},
		)
	} else if kit.menu_item("new_playlist", "New Playlist…", tone = .Primary).is_activated {
		is_naming = true
		kit.focus_input(&playlist_name_field)
	}

	kit.menu_separator()

	playlists, _, phase := core.watch_playlists()
	editable_count := 0
	for playlist in playlists do if playlist.can_edit do editable_count += 1

	list_height := min(
		f32(editable_count) * (kit.MENU_ITEM_HEIGHT + PLAYLIST_ITEM_GAP),
		MAX_PLAYLIST_LIST_HEIGHT,
	)
	list := ui.box(
		"playlists",
		{
			width = ui.fill(),
			height = ui.points(list_height),
			axis = .Y,
			gap = PLAYLIST_ITEM_GAP,
			flags = {.Scroll, .Clip},
		},
	)

	if ui.scope(list) {
		for playlist in playlists {
			if !playlist.can_edit do continue

			if kit.menu_item(fmt.tprintf("playlist_%s", playlist.id), playlist.name).is_activated {
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
				text_color = kit.with_opacity(kit.colors.base_content, 0.5),
				font_size = 12,
				padding = {8, 4, 8, 4},
			},
			look.to_phase_text(phase) if phase != .Ready else "No playlists of yours yet.",
		)
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
