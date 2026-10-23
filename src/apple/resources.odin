package apple

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

Artwork :: struct {
	// It has {w}, {h} and {f} in place of the size and the format.
	url:              string,
	background_color: string `json:"bgColor"`,
	text_color:       string `json:"textColor1"`,
}

Catalog_Song :: struct {
	id:               string,
	name:             string,
	artist_name:      string `json:"artistName"`,
	album_name:       string `json:"albumName"`,
	duration_seconds: f64 `json:"durationSeconds"`,
	is_lossless:      bool `json:"isLossless"`,
	artwork:          Artwork,
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
	YouTube_Playlist,
	YouTube_Artist,
}

Card :: struct {
	id:       string,
	kind:     Card_Kind,
	name:     string,
	subtitle: string,
	artwork:  Artwork,
	song:     Catalog_Song,
	can_edit: bool,
}

Shelf :: struct {
	title:      string,
	cards:      []Card,
	is_youtube: bool,
	is_wide:    bool,
}

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

Search_Answer :: struct {
	results: struct {
		songs:           Related,
		albums:          Related,
		artists:         Related,
		library_artists: Related `json:"library-artists"`,
	},
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
	number_on_disc:          int `json:"trackNumber"`,
	disc_number:             int `json:"discNumber"`,
	url:                     string,
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
	song_count:              int `json:"trackCount"`,
	editorial_notes:         struct {
		standard: string,
		short:    string,
	} `json:"editorialNotes"`,
	// Apple omits these on some playlists. watch_playlists tells a missing value from false.
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

to_catalog_songs :: proc(resources: []Resource, allocator := context.allocator) -> []Catalog_Song {
	songs := make([]Catalog_Song, len(resources), allocator)
	for resource, index in resources do songs[index] = to_catalog_song(resource)

	return songs
}

// A library song plays by its catalog ID. A song uploaded from a Mac keeps its library ID.
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

to_cards :: proc(resources: []Resource, allocator := context.allocator) -> []Card {
	cards := make([dynamic]Card, allocator)

	for resource in resources {
		card := to_card(resource)
		if card.kind != .Other do append(&cards, card)
	}

	return cards[:]
}

read_related :: proc(resource: Resource, name: string) -> []Resource {
	related, ok := resource.relationships[name]

	return related.data if ok else nil
}

read_view :: proc(resource: Resource, name: string) -> []Resource {
	view, ok := resource.views[name]

	return view.data if ok else nil
}

HOME_PATH :: "/v1/me/recommendations?limit=10"
NEW_PATH :: "/v1/editorial/" + STOREFRONT + "/groupings?platform=web&name=music"

to_home_shelves :: proc(body: string, allocator := context.allocator) -> []Shelf {
	shelves := make([dynamic]Shelf, allocator)

	for resource in to_resources(body, allocator) {
		cards := to_cards(read_related(resource, "contents"), allocator)
		if len(cards) == 0 do continue

		append(
			&shelves,
			Shelf{title = resource.attributes.title.string_for_display, cards = cards},
		)
	}

	return shelves[:]
}

// New is Apple's editorial page "music". The app skips a shelf with no name, which is a banner.
to_new_shelves :: proc(body: string, allocator := context.allocator) -> []Shelf {
	groupings := to_resources(body, allocator)
	if len(groupings) == 0 do return nil

	tabs := read_related(groupings[0], "tabs")
	if len(tabs) == 0 do return nil

	shelves := make([dynamic]Shelf, allocator)

	for element in read_related(tabs[0], "children") {
		cards := to_cards(read_related(element, "contents"), allocator)
		if element.attributes.name == "" || len(cards) == 0 do continue

		append(&shelves, Shelf{title = element.attributes.name, cards = cards})
	}

	return shelves[:]
}

to_artwork_url :: proc(
	artwork: Artwork,
	width_pixels: int,
	height_pixels := 0,
	allocator := context.temp_allocator,
) -> string {
	if artwork.url == "" do return ""

	final_height_pixels := height_pixels if height_pixels > 0 else width_pixels
	with_width, _ := strings.replace_all(
		artwork.url,
		"{w}",
		fmt.tprintf("%d", width_pixels),
		context.temp_allocator,
	)
	with_height, _ := strings.replace_all(
		with_width,
		"{h}",
		fmt.tprintf("%d", final_height_pixels),
		context.temp_allocator,
	)

	// "ac" puts an artist's album cover on a square of its colour. "cc" crops it to fill.
	size := fmt.tprintf("%dx%d", width_pixels, final_height_pixels)
	cropped, _ := strings.replace_all(
		with_height,
		fmt.tprintf("%sac.", size),
		fmt.tprintf("%scc.", size),
		context.temp_allocator,
	)
	url, _ := strings.replace_all(cropped, "{f}", "jpg", allocator)

	return url
}
