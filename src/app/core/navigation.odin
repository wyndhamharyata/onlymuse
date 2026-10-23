package core

import "core:encoding/json"
import "core:strings"
import "om:store"
import "om:ui"

Page_Kind :: enum {
	Home,
	New,
	Favourite_Songs,
	Recently_Added,
	Artists,
	Albums,
	Songs,
	Downloaded,
	Playlist,
	Catalog_Playlist,
	Album,
	Artist,
	Artist_Recent_Songs,
	Search,
	Now_Playing,
	YouTube_Playlist,
	YouTube_Mixes,
	Bring_Over,
	Console,
}

Page :: struct {
	kind:  Page_Kind,
	id:    string,
	title: string,
}

MAX_PAGE_COUNT :: 50

navigation: struct {
	pages:   [dynamic]Page,
	scrolls: [dynamic]f32,
	index:   int,
}

current_page :: proc() -> Page {
	return navigation.pages[navigation.index]
}

navigation_visit: int

navigate :: proc(chosen: Page) {
	if current_page() == chosen do return

	page := Page {
		kind  = chosen.kind,
		id    = strings.clone(chosen.id),
		title = strings.clone(chosen.title),
	}

	kept := navigation.index + 1
	resize(&navigation.pages, kept)
	resize(&navigation.scrolls, kept)
	append(&navigation.pages, page)
	append(&navigation.scrolls, 0)

	if len(navigation.pages) > MAX_PAGE_COUNT {
		ordered_remove(&navigation.pages, 0)
		ordered_remove(&navigation.scrolls, 0)
	}

	navigation.index = len(navigation.pages) - 1
	save_visit()
}

@(private = "file")
save_visit :: proc() {
	navigation_visit += 1
	save_navigation()
}

can_go_back :: proc() -> bool {
	return navigation.index > 0
}

can_go_forward :: proc() -> bool {
	return navigation.index < len(navigation.pages) - 1
}

go_back :: proc() {
	if can_go_back() do navigation.index -= 1
	save_visit()
}

go_forward :: proc() {
	if can_go_forward() do navigation.index += 1
	save_visit()
}

@(private = "file")
Saved_Page :: struct {
	id:          string,
	album_id:    string `json:"albumId"`,
	artist_id:   string `json:"artistId"`,
	playlist_id: string `json:"playlistId"`,
	term:        string,
	artist_name: string `json:"artistName"`,
	playlist:    struct {
		id:   string,
		name: string,
	},
}

@(private = "file")
Saved_Navigation :: struct {
	pages:   []Saved_Page,
	index:   int,
	scrolls: []f32,
}

@(private = "file")
page_ids := [Page_Kind]string {
	.Home                = "home",
	.New                 = "new",
	.Favourite_Songs     = "favouriteSongs",
	.Recently_Added      = "recentlyAdded",
	.Artists             = "artists",
	.Albums              = "albums",
	.Songs               = "songs",
	.Downloaded          = "downloaded",
	.Playlist            = "playlist",
	.Catalog_Playlist    = "catalogPlaylist",
	.Album               = "album",
	.Artist              = "artist",
	.Artist_Recent_Songs = "artistRecentSongs",
	.Search              = "search",
	.Now_Playing         = "nowPlaying",
	.YouTube_Playlist    = "youtubePlaylist",
	.YouTube_Mixes       = "youtubeMixes",
	.Bring_Over          = "bringOver",
	.Console             = "console",
}

@(private = "file")
to_saved_page :: proc(page: Page) -> Saved_Page {
	saved := Saved_Page {
		id = page_ids[page.kind],
	}

	#partial switch page.kind {
	case .Playlist, .YouTube_Playlist, .Bring_Over:
		saved.playlist = {page.id, page.title}
	case .Catalog_Playlist:
		saved.playlist_id = page.id
	case .Album:
		saved.album_id = page.id
	case .Artist, .Artist_Recent_Songs:
		saved.artist_id = page.id
		saved.artist_name = page.title
	case .Search:
		saved.term = page.id
	}

	return saved
}

@(private = "file")
to_page :: proc(saved: Saved_Page) -> (Page, bool) {
	for id, kind in page_ids {
		if id != saved.id do continue

		page := Page {
			kind = kind,
		}

		#partial switch kind {
		case .Playlist, .YouTube_Playlist, .Bring_Over:
			page.id = saved.playlist.id
			page.title = saved.playlist.name
		case .Catalog_Playlist:
			page.id = saved.playlist_id
		case .Album:
			page.id = saved.album_id
		case .Artist, .Artist_Recent_Songs:
			page.id = saved.artist_id
			page.title = saved.artist_name
		case .Search:
			page.id = saved.term
		}

		return page, true
	}

	return {}, false
}

save_navigation :: proc() {
	pages := make([]Saved_Page, len(navigation.pages), context.temp_allocator)
	for page, index in navigation.pages do pages[index] = to_saved_page(page)

	bytes, error := json.marshal(
		Saved_Navigation{pages, navigation.index, navigation.scrolls[:]},
		allocator = context.temp_allocator,
	)
	if error == nil do store.save_state("navigation", string(bytes))
}

start_navigation :: proc() {
	text, has_text := store.find_state("navigation")
	saved: Saved_Navigation
	is_read := has_text && json.unmarshal_string(text, &saved) == nil

	if is_read {
		for saved_page, index in saved.pages {
			page, is_page := to_page(saved_page)
			if !is_page do continue

			append(&navigation.pages, page)
			append(&navigation.scrolls, saved.scrolls[index] if index < len(saved.scrolls) else 0)
		}
	}

	if len(navigation.pages) == 0 {
		append(&navigation.pages, Page{kind = .Home})
		append(&navigation.scrolls, 0)
	}

	navigation.index = clamp(saved.index, 0, len(navigation.pages) - 1)

	navigation_visit = 1
}

keep_scroll :: proc(page_box: ^ui.Box) {
	index := navigation.index
	saved := navigation.scrolls[index]

	if restore.visit != navigation_visit {
		restore = {
			visit       = navigation_visit,
			frames_left = RESTORE_FRAME_COUNT if saved > 0 else 0,
		}
	}

	if restore.frames_left > 0 {
		max_scroll := max(0, page_box.content_size.y - page_box.size.y)
		is_scrolled_away :=
			page_box.size.y > 0 &&
			page_box.scroll_target != saved &&
			page_box.scroll_target != max_scroll

		if !is_scrolled_away {
			restore.frames_left -= 1
			is_tall_enough := page_box.size.y > 0 && max_scroll >= saved
			if is_tall_enough do restore.frames_left = 0
			ui.set_scroll(page_box, saved)
			return
		}

		restore.frames_left = 0
	}

	if page_box.scroll == saved do return

	navigation.scrolls[index] = page_box.scroll
	is_scroll_changed = true
}

RESTORE_FRAME_COUNT :: 240

@(private = "file")
restore: struct {
	visit:       int,
	frames_left: int,
}

is_scroll_changed: bool
