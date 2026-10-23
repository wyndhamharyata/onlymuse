package core

import "core:mem"
import "core:strings"
import "om:apple"

copy_song :: proc(song: Catalog_Song, allocator := context.allocator) -> Catalog_Song {
	copied := song
	copied.id = strings.clone(song.id, allocator)
	copied.name = strings.clone(song.name, allocator)
	copied.artist_name = strings.clone(song.artist_name, allocator)
	copied.album_name = strings.clone(song.album_name, allocator)
	copied.youtube_id = strings.clone(song.youtube_id, allocator)
	copied.artwork = copy_artwork(song.artwork, allocator)

	return copied
}

copy_card :: proc(card: apple.Card, allocator: mem.Allocator) -> apple.Card {
	copied := card
	copied.id = strings.clone(card.id, allocator)
	copied.name = strings.clone(card.name, allocator)
	copied.subtitle = strings.clone(card.subtitle, allocator)
	copied.artwork = copy_artwork(card.artwork, allocator)
	copied.song = copy_song(card.song, allocator)

	return copied
}

copy_artwork :: proc(artwork: apple.Artwork, allocator: mem.Allocator) -> apple.Artwork {
	return {
		strings.clone(artwork.url, allocator),
		strings.clone(artwork.background_color, allocator),
		strings.clone(artwork.text_color, allocator),
	}
}

copy_shelf :: proc(shelf: apple.Shelf, allocator: mem.Allocator) -> apple.Shelf {
	cards := make([]apple.Card, len(shelf.cards), allocator)
	for card, index in shelf.cards do cards[index] = copy_card(card, allocator)

	return {
		title = strings.clone(shelf.title, allocator),
		cards = cards,
		is_youtube = shelf.is_youtube,
		is_wide = shelf.is_wide,
	}
}

Catalog_Song :: apple.Catalog_Song

delete_song :: proc(song: Catalog_Song) {
	delete(song.id)
	delete(song.name)
	delete(song.artist_name)
	delete(song.album_name)
	delete(song.youtube_id)
	delete(song.artwork.url)
	delete(song.artwork.background_color)
	delete(song.artwork.text_color)
}
