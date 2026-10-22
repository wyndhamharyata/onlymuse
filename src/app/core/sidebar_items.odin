package core

import "om:youtube"

// Only the palette opens the Console, as it is for finding out what went wrong, not for listening.
console_items := []Sidebar_Item{{.Console, "Console", "exclamationmark.triangle"}}

Sidebar_Item :: struct {
	kind:   Page_Kind,
	label:  string,
	symbol: string,
}

apple_music_items := []Sidebar_Item{{.Home, "Home", "house"}, {.New, "New", "square.grid.2x2"}}

youtube_items := []struct {
	label:  string,
	symbol: string,
	page:   Page,
} {
	{"Mixes", "dot.radiowaves.left.and.right", {kind = .YouTube_Mixes}},
	{"Liked Music", "hand.thumbsup", {kind = .YouTube_Playlist, id = youtube.LIKED_ID, title = "Liked Music"}},
	{"Bring Over", "square.and.arrow.down", {kind = .Bring_Over}},
}

library_items := []Sidebar_Item {
	{.Favourite_Songs, "Favourite Songs", "star"},
	{.Recently_Added, "Recently Added", "clock"},
	{.Artists, "Artists", "music.mic"},
	{.Albums, "Albums", "square.stack"},
	{.Songs, "Songs", "music.note"},
	{.Downloaded, "Downloaded", "arrow.down.circle"},
}
