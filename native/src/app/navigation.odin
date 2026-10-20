package app

import "core:encoding/json"
import "om:store"

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
	Search,
}

Page :: struct {
	kind:  Page_Kind,
	// The playlist, album or artist ID, or the search term.
	id:    string,
	title: string,
}

MAX_PAGE_COUNT :: 50

navigation: struct {
	pages: [dynamic]Page,
	index: int,
}

current_page :: proc() -> Page {
	return navigation.pages[navigation.index]
}

// Opens a page after the current one. Pages after the current one, from Back, are dropped.
navigate :: proc(page: Page) {
	if len(navigation.pages) > 0 && current_page() == page do return

	resize(&navigation.pages, navigation.index + 1 if len(navigation.pages) > 0 else 0)
	append(&navigation.pages, page)

	if len(navigation.pages) > MAX_PAGE_COUNT do ordered_remove(&navigation.pages, 0)

	navigation.index = len(navigation.pages) - 1
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
	save_navigation()
}

go_forward :: proc() {
	if can_go_forward() do navigation.index += 1
	save_navigation()
}

// The saved form, as the gpuix app wrote it under "navigation".
@(private = "file")
Saved_Page :: struct {
	id:          string,
	album_id:    string `json:"albumId"`,
	artist_id:   string `json:"artistId"`,
	playlist_id: string `json:"playlistId"`,
	term:        string,
	// The native app's own, for an artist opened by name from the player bar.
	artist_name: string `json:"artistName"`,
	playlist:    struct {
		id:   string,
		name: string,
	},
}

@(private = "file")
Saved_Navigation :: struct {
	pages: []Saved_Page,
	index: int,
}

@(private = "file")
page_ids := [Page_Kind]string {
	.Home             = "home",
	.New              = "new",
	.Favourite_Songs  = "favouriteSongs",
	.Recently_Added   = "recentlyAdded",
	.Artists          = "artists",
	.Albums           = "albums",
	.Songs            = "songs",
	.Downloaded       = "downloaded",
	.Playlist         = "playlist",
	.Catalog_Playlist = "catalogPlaylist",
	.Album            = "album",
	.Artist           = "artist",
	.Search           = "search",
}

@(private = "file")
to_saved_page :: proc(page: Page) -> Saved_Page {
	saved := Saved_Page{id = page_ids[page.kind]}

	#partial switch page.kind {
	case .Playlist:
		saved.playlist = {page.id, page.title}
	case .Catalog_Playlist:
		saved.playlist_id = page.id
	case .Album:
		saved.album_id = page.id
	case .Artist:
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

		page := Page{kind = kind}
		#partial switch kind {
		case .Playlist:
			page.id = saved.playlist.id
			page.title = saved.playlist.name
		case .Catalog_Playlist:
			page.id = saved.playlist_id
		case .Album:
			page.id = saved.album_id
		case .Artist:
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

	bytes, error := json.marshal(Saved_Navigation{pages, navigation.index}, allocator = context.temp_allocator)
	if error == nil do store.save_state("navigation", string(bytes))
}

// The pages of the last run, with Back and Forward as they were. Albums when there are none.
start_navigation :: proc() {
	if text, ok := store.find_state("navigation"); ok {
		saved: Saved_Navigation
		if json.unmarshal_string(text, &saved) == nil {
			for saved_page in saved.pages {
				if page, is_page := to_page(saved_page); is_page do append(&navigation.pages, page)
			}
			navigation.index = clamp(saved.index, 0, len(navigation.pages) - 1)
		}
	}

	if len(navigation.pages) == 0 do append(&navigation.pages, Page{kind = .Albums})
}
