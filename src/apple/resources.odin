package apple

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

Artwork :: struct {
	// Has {w}, {h} and {f} in place of the size and format.
	url:         string,
	// Hex, as "2a2a2f", the colour behind the picture. Catalog artwork has it, library artwork does not.
	bg_color:    string `json:"bgColor"`,
	// The colour of text that would sit on the picture, its strongest other colour.
	text_color1: string `json:"textColor1"`,
}

Catalog_Song :: struct {
	id:               string,
	name:             string,
	artist_name:      string `json:"artistName"`,
	album_name:       string `json:"albumName"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	is_lossless:      bool `json:"isLossless"`,
	artwork:          Artwork,
	// The YouTube video an Apple song was matched from, so it can go back to YouTube. Empty for any other song.
	youtube_id:       string `json:"youtubeId"`,
}

Card_Kind :: enum {
	Other,
	Album,
	Library_Album,
	Artist,
	Playlist,
	Library_Playlist,
	Song,
	// A YouTube Music album, playlist or mix. src/youtube reads these.
	YouTube_Playlist,
	YouTube_Artist,
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
	// A library playlist the person made, which takes new songs.
	can_edit: bool,
}

Shelf :: struct {
	title:      string,
	cards:      []Card,
	is_youtube: bool,
	// Its cards are videos, shown in 16:9.
	is_wide:    bool,
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
	name:                    string,
	artist_name:             string `json:"artistName"`,
	album_name:              string `json:"albumName"`,
	curator_name:            string `json:"curatorName"`,
	duration_ms:             f64 `json:"durationInMillis"`,
	artwork:                 Artwork,
	audio_traits:            []string `json:"audioTraits"`,
	play_params:             struct {
		catalog_id: string `json:"catalogId"`,
	} `json:"playParams"`,
	genre_names:             []string `json:"genreNames"`,
	release_date:            string `json:"releaseDate"`,
	title:                   struct {
		string_for_display: string `json:"stringForDisplay"`,
	},
	description:             struct {
		standard: string,
		short:    string,
	},
	track_number:            int `json:"trackNumber"`,
	disc_number:             int `json:"discNumber"`,
	// The item's page on music.apple.com.
	url:                     string,
	// A song's and its album's details, for the Now Playing page.
	composer_name:           string `json:"composerName"`,
	album_artist_name:       string `json:"albumArtistName"`,
	isrc:                    string,
	content_rating:          string `json:"contentRating"`,
	audio_locale:            string `json:"audioLocale"`,
	has_lyrics:              bool `json:"hasLyrics"`,
	has_time_synced_lyrics:  bool `json:"hasTimeSyncedLyrics"`,
	is_apple_digital_master: bool `json:"isAppleDigitalMaster"`,
	record_label:            string `json:"recordLabel"`,
	copyright:               string,
	track_count:             int `json:"trackCount"`,
	editorial_notes:         struct {
		standard: string,
		short:    string,
	} `json:"editorialNotes"`,
	can_edit:                Maybe(bool) `json:"canEdit"`,
	can_delete:              Maybe(bool) `json:"canDelete"`,
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
		id = resource.id,
		name = attributes.name,
		artist_name = attributes.artist_name,
		album_name = attributes.album_name,
		duration_seconds = attributes.duration_ms / 1000,
		is_lossless = slice.contains(attributes.audio_traits, "lossless"),
		artwork = attributes.artwork,
	}
}

// A library song plays by its catalog ID. A song uploaded from a Mac has none, so it keeps its library ID.
to_library_song :: proc(resource: Resource) -> Catalog_Song {
	song := to_catalog_song(resource)
	if resource.attributes.play_params.catalog_id != "" {
		song.id = resource.attributes.play_params.catalog_id
	}

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
	card.can_edit = attributes.can_edit.? or_else false

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
		if len(cards) > 0 {
			append(
				&shelves,
				Shelf{title = resource.attributes.title.string_for_display, cards = cards},
			)
		}
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
		if element.attributes.name != "" && len(cards) > 0 {
			append(&shelves, Shelf{title = element.attributes.name, cards = cards})
		}
	}

	return shelves[:]
}

// A height of 0 asks for a square.
to_artwork_url :: proc(
	artwork: Artwork,
	width_pixels: int,
	height_pixels := 0,
	allocator := context.temp_allocator,
) -> string {
	if artwork.url == "" do return ""

	height := height_pixels if height_pixels > 0 else width_pixels
	with_width, _ := strings.replace_all(
		artwork.url,
		"{w}",
		fmt.tprintf("%d", width_pixels),
		context.temp_allocator,
	)
	with_height, _ := strings.replace_all(
		with_width,
		"{h}",
		fmt.tprintf("%d", height),
		context.temp_allocator,
	)
	// "ac" puts an artist's album cover on a square of its colour. "cc" crops it to fill.
	size := fmt.tprintf("%dx%d", width_pixels, height)
	cropped, _ := strings.replace_all(
		with_height,
		fmt.tprintf("%sac.", size),
		fmt.tprintf("%scc.", size),
		context.temp_allocator,
	)
	url, _ := strings.replace_all(cropped, "{f}", "jpg", allocator)

	return url
}
