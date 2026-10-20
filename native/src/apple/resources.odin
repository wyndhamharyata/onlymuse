package apple

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

Artwork :: struct {
	// Has {w}, {h} and {f} in place of the size and format.
	url: string,
}

Catalog_Song :: struct {
	id:               string,
	name:             string,
	artist_name:      string `json:"artistName"`,
	album_name:       string `json:"albumName"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	is_lossless:      bool `json:"isLossless"`,
	artwork:          Artwork,
}

Card_Kind :: enum {
	Other,
	Album,
	Library_Album,
	Artist,
	Playlist,
	Library_Playlist,
	Song,
}

// One tile on a shelf or a grid.
Card :: struct {
	id:       string,
	kind:     Card_Kind,
	name:     string,
	subtitle: string,
	artwork:  Artwork,
	// Set on a song card, so the shelf can play its songs in order.
	song:     Catalog_Song,
}

Shelf :: struct {
	title: string,
	cards: []Card,
}

// The parts of Apple's resources the app reads. The answers hold much more.
Resource :: struct {
	id:            string,
	type:          string,
	attributes:    Attributes,
	relationships: map[string]Related,
	views:         map[string]Related,
}

Related :: struct {
	data: []Resource,
}

Attributes :: struct {
	name:                   string,
	artist_name:            string `json:"artistName"`,
	album_name:             string `json:"albumName"`,
	curator_name:           string `json:"curatorName"`,
	duration_ms:            f64 `json:"durationInMillis"`,
	artwork:                Artwork,
	audio_traits:           []string `json:"audioTraits"`,
	play_params:            struct {
		catalog_id: string `json:"catalogId"`,
	} `json:"playParams"`,
	genre_names:            []string `json:"genreNames"`,
	release_date:           string `json:"releaseDate"`,
	title:                  struct {
		string_for_display: string `json:"stringForDisplay"`,
	},
	description:            struct {
		standard: string,
		short:    string,
	},
	track_number:           int `json:"trackNumber"`,
	disc_number:            int `json:"discNumber"`,
	can_edit:               Maybe(bool) `json:"canEdit"`,
	can_delete:             Maybe(bool) `json:"canDelete"`,
}

@(private)
to_card_kind :: proc(type: string) -> Card_Kind {
	switch type {
	case "albums":
		return .Album
	case "library-albums":
		return .Library_Album
	case "artists":
		return .Artist
	case "playlists":
		return .Playlist
	case "library-playlists":
		return .Library_Playlist
	case "songs":
		return .Song
	}

	return .Other
}

// The data of an answer, read into allocator, such as a page's arena.
to_resources :: proc(body: string, allocator := context.allocator) -> []Resource {
	Answer_Body :: struct {
		data: []Resource,
	}
	answer: Answer_Body
	if json.unmarshal_string(body, &answer, allocator = allocator) != nil do return nil

	return answer.data
}

to_catalog_song :: proc(resource: Resource) -> Catalog_Song {
	attributes := resource.attributes

	return Catalog_Song {
		id               = resource.id,
		name             = attributes.name,
		artist_name      = attributes.artist_name,
		album_name       = attributes.album_name,
		duration_seconds = attributes.duration_ms / 1000,
		is_lossless      = slice.contains(attributes.audio_traits, "lossless"),
		artwork          = attributes.artwork,
	}
}

// A library song plays by its catalog ID. A song uploaded from a Mac has none, so it keeps its library ID.
to_library_song :: proc(resource: Resource) -> Catalog_Song {
	song := to_catalog_song(resource)
	if resource.attributes.play_params.catalog_id != "" do song.id = resource.attributes.play_params.catalog_id

	return song
}

to_card :: proc(resource: Resource) -> Card {
	attributes := resource.attributes
	card := Card {
		id       = resource.id,
		kind     = to_card_kind(resource.type),
		name     = attributes.name,
		subtitle = attributes.curator_name if attributes.curator_name != "" else attributes.artist_name,
		artwork  = attributes.artwork,
	}
	if card.kind == .Song do card.song = to_catalog_song(resource)

	return card
}

// A shelf can hold stations, radio shows and videos. The app has no page for those, so they stay out.
list_cards :: proc(resources: []Resource, allocator := context.allocator) -> []Card {
	cards := make([dynamic]Card, allocator)

	for resource in resources {
		card := to_card(resource)
		if card.kind != .Other do append(&cards, card)
	}

	return cards[:]
}

list_related :: proc(resource: Resource, name: string) -> []Resource {
	related, ok := resource.relationships[name]

	return related.data if ok else nil
}

list_view :: proc(resource: Resource, name: string) -> []Resource {
	view, ok := resource.views[name]

	return view.data if ok else nil
}

HOME_PATH :: "/v1/me/recommendations?limit=10"
NEW_PATH :: "/v1/editorial/" + STOREFRONT + "/groupings?platform=web&name=music"

to_home_shelves :: proc(body: string, allocator := context.allocator) -> []Shelf {
	shelves := make([dynamic]Shelf, allocator)

	for resource in to_resources(body, allocator) {
		cards := list_cards(list_related(resource, "contents"), allocator)
		if len(cards) > 0 do append(&shelves, Shelf{resource.attributes.title.string_for_display, cards})
	}

	return shelves[:]
}

// New is Apple's editorial page "music", a list of named shelves. A shelf with no name is a banner, which the app skips.
to_new_shelves :: proc(body: string, allocator := context.allocator) -> []Shelf {
	shelves := make([dynamic]Shelf, allocator)
	groupings := to_resources(body, allocator)
	if len(groupings) == 0 do return nil

	tabs := list_related(groupings[0], "tabs")
	if len(tabs) == 0 do return nil

	for element in list_related(tabs[0], "children") {
		cards := list_cards(list_related(element, "contents"), allocator)
		if element.attributes.name != "" && len(cards) > 0 do append(&shelves, Shelf{element.attributes.name, cards})
	}

	return shelves[:]
}

to_artwork_url :: proc(artwork: Artwork, size_pixels: int, allocator := context.temp_allocator) -> string {
	if artwork.url == "" do return ""

	size := fmt.tprintf("%d", size_pixels)
	with_width, _ := strings.replace_all(artwork.url, "{w}", size, context.temp_allocator)
	with_height, _ := strings.replace_all(with_width, "{h}", size, context.temp_allocator)
	url, _ := strings.replace_all(with_height, "{f}", "jpg", allocator)

	return url
}
