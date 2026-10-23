package matching

import "core:testing"
import "om:app/core"

@(test)
test_to_match_key :: proc(t: ^testing.T) {
	testing.expect_value(t, to_match_key("Oikaze (Official Video)"), "oikaze")
	testing.expect_value(t, to_match_key("Song feat. Someone"), "song")
	testing.expect_value(t, to_match_key("SHE'S"), "shes")
	testing.expect_value(t, to_match_key("【MV】"), "mv")
}

@(test)
test_is_same_recording :: proc(t: ^testing.T) {
	youtube_song := core.Catalog_Song {
		name             = "追い風 - Oikaze",
		artist_name      = "Ado",
		duration_seconds = 200,
	}
	apple_song := core.Catalog_Song {
		name             = "Oikaze",
		artist_name      = "ADO",
		duration_seconds = 202,
	}
	testing.expect(t, is_same_recording(youtube_song, apple_song))

	longer := apple_song
	longer.duration_seconds = 210
	testing.expect(t, !is_same_recording(youtube_song, longer))

	other_artist := apple_song
	other_artist.artist_name = "Eve"
	testing.expect(t, !is_same_recording(youtube_song, other_artist))

	// A known limit: one artist key inside the other counts as the same artist.
	shadow := apple_song
	shadow.artist_name = "Shadow"
	testing.expect(t, is_same_recording(youtube_song, shadow))
}
