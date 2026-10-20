package app

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
}

can_go_back :: proc() -> bool {
	return navigation.index > 0
}

can_go_forward :: proc() -> bool {
	return navigation.index < len(navigation.pages) - 1
}

go_back :: proc() {
	if can_go_back() do navigation.index -= 1
}

go_forward :: proc() {
	if can_go_forward() do navigation.index += 1
}
