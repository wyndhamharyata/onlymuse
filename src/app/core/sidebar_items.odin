package core

import "om:youtube"

console_items := []Sidebar_Item{{"Console", "exclamationmark.triangle", {kind = .Console}}}

Sidebar_Item :: struct {
	label:  string,
	symbol: string,
	page:   Page,
}

apple_music_items := []Sidebar_Item {
	{"Home", "house", {kind = .Home}},
	{"New", "square.grid.2x2", {kind = .New}},
}

youtube_items := []Sidebar_Item {
	{"Mixes", "dot.radiowaves.left.and.right", {kind = .YouTube_Mixes}},
	{
		"Liked Music",
		"hand.thumbsup",
		{kind = .YouTube_Playlist, id = youtube.LIKED_ID, title = "Liked Music"},
	},
	{"Bring Over", "square.and.arrow.down", {kind = .Bring_Over}},
}

library_items := []Sidebar_Item {
	{"Favourite Songs", "star", {kind = .Favourite_Songs}},
	{"Recently Added", "clock", {kind = .Recently_Added}},
	{"Artists", "music.mic", {kind = .Artists}},
	{"Albums", "square.stack", {kind = .Albums}},
	{"Songs", "music.note", {kind = .Songs}},
	{"Downloaded", "arrow.down.circle", {kind = .Downloaded}},
}
