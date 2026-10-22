package playback

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:helper"
import "om:store"
import "om:ui"

// A song skipped this often, and more often than played, is often skipped.
OFTEN_SKIPPED_COUNT :: 3

// A favourite is this many times as likely to come early.
FAVOURITE_WEIGHT :: 2.5

RECENT_HOUR_CHOICES :: [?]int{0, 2, 6, 24}

Shuffle_Rules :: struct {
	// Songs played this many hours ago or since go last. 0 leaves them.
	recent_hours:      int `json:"recentHours"`,
	skipped_go_last:   bool `json:"skippedGoLast"`,
	albums_apart:      bool `json:"albumsApart"`,
	favourites_first:  bool `json:"favouritesFirst"`,
}

shuffle_rules := Shuffle_Rules{recent_hours = 6, skipped_go_last = true, albums_apart = true}

// What the last shuffle did, for Up Next. Empty when the rules changed nothing.
shuffle_note: string

start_shuffle_rules :: proc() {
	if text, ok := store.find_state("shuffleRules", context.temp_allocator); ok {
		_ = json.unmarshal_string(text, &shuffle_rules, allocator = context.temp_allocator)
	}
}

@(private = "file")
save_shuffle_rules :: proc() {
	bytes, error := json.marshal(shuffle_rules, allocator = context.temp_allocator)
	if error == nil do store.save_state("shuffleRules", string(bytes))
}

// A random order, then the rules: favourites drawn early, recent and often-skipped songs moved to the
// end in their shuffled order, and no album twice in a row where another song can go between.
shuffle_by_rules :: proc(songs: []core.Catalog_Song) -> []core.Catalog_Song {
	shuffled := make([]core.Catalog_Song, len(songs))
	copy(shuffled, songs)

	if shuffle_rules.favourites_first {
		// Efraimidis and Spirakis: each song draws u^(1/weight) and the largest go first.
		Keyed :: struct {
			key:  f64,
			song: core.Catalog_Song,
		}
		keyed := make([]Keyed, len(shuffled), context.temp_allocator)
		for song, index in shuffled {
			weight := FAVOURITE_WEIGHT if is_favourite(song) else 1
			keyed[index] = {math.pow(rand.float64(), 1 / weight), song}
		}
		slice.sort_by(keyed, proc(a, b: Keyed) -> bool {return a.key > b.key})
		for item, index in keyed do shuffled[index] = item.song
	} else {
		rand.shuffle(shuffled)
	}

	recent, skipped := find_song_history()
	recent_count, skipped_count := 0, 0
	kept := make([dynamic]core.Catalog_Song, context.temp_allocator)
	later := make([dynamic]core.Catalog_Song, context.temp_allocator)

	for song in shuffled {
		key := to_song_key(song)
		switch {
		case shuffle_rules.recent_hours > 0 && recent[key]:
			recent_count += 1
			append(&later, song)
		case shuffle_rules.skipped_go_last && skipped[key]:
			skipped_count += 1
			append(&later, song)
		case:
			append(&kept, song)
		}
	}

	// All of them recent or skipped, and the order stays as drawn.
	if len(kept) > 0 {
		copy(shuffled, kept[:])
		copy(shuffled[len(kept):], later[:])
	}

	apart_count := 0
	// Each part on its own, so a song that plays last never moves ahead.
	if shuffle_rules.albums_apart {
		apart_count = keep_albums_apart(shuffled[:len(kept)]) + keep_albums_apart(shuffled[len(kept):])
	}

	set_shuffle_note(recent_count, skipped_count, apart_count)

	return shuffled
}

// A song's key in the play log's terms: its name and artist, as a song started in Music.app has no ID.
@(private = "file")
to_song_key :: proc(song: core.Catalog_Song) -> string {
	return fmt.tprintf("%s\x1f%s", song.name, song.artist_name)
}

// Songs played within the rule's hours, and songs skipped often, by key.
@(private = "file")
find_song_history :: proc() -> (recent, skipped: map[string]bool) {
	recent = make(map[string]bool, context.temp_allocator)
	skipped = make(map[string]bool, context.temp_allocator)
	since := i64(helper.now_ms()) - i64(shuffle_rules.recent_hours) * 3_600_000
	plays := make(map[string]int, context.temp_allocator)
	skips := make(map[string]int, context.temp_allocator)

	for play in play_log {
		key := fmt.tprintf("%s\x1f%s", play.name, play.artist)
		if play.is_skip {
			skips[key] += 1
		} else {
			plays[key] += 1
			if play.played_at >= since do recent[key] = true
		}
	}

	for key, count in skips {
		if count >= OFTEN_SKIPPED_COUNT && count > plays[key] {
			skipped[key] = true
		}
	}

	return
}

// Swaps a song that follows one of its own album with the next song from another. Returns how many moved.
@(private = "file")
keep_albums_apart :: proc(songs: []core.Catalog_Song) -> int {
	moved := 0

	for index in 1 ..< len(songs) {
		if songs[index].album_name != songs[index - 1].album_name do continue

		for other in index + 1 ..< len(songs) {
			if songs[other].album_name == songs[index - 1].album_name do continue

			songs[index], songs[other] = songs[other], songs[index]
			moved += 1
			break
		}
	}

	return moved
}

@(private = "file")
set_shuffle_note :: proc(recent_count, skipped_count, apart_count: int) {
	// "4 recent songs and 1 often-skipped song play last."
	parts := make([dynamic]string, context.temp_allocator)
	if recent_count > 0 {
		append(&parts, fmt.tprintf("%d recent %s", recent_count, "song" if recent_count == 1 else "songs"))
	}
	if skipped_count > 0 {
		append(&parts, fmt.tprintf("%d often-skipped %s", skipped_count, "song" if skipped_count == 1 else "songs"))
	}

	note := ""
	if len(parts) > 0 {
		note = fmt.tprintf("%s %s last.", strings.join(parts[:], " and ", context.temp_allocator), "plays" if recent_count + skipped_count == 1 else "play")
	}
	if apart_count > 0 {
		note = fmt.tprintf("%s%sSongs from one album don't play back to back.", note, " " if note != "" else "")
	}

	delete(shuffle_note)
	shuffle_note = strings.clone(note)
}

@(private = "file")
rules_menu: struct {
	is_open:      bool,
	position:     [2]f32,
	opened_frame: int,
}

open_shuffle_rules :: proc(position: [2]f32) {
	rules_menu = {true, position, core.app.frame_count}
}

build_shuffle_rules :: proc() {
	if !rules_menu.is_open do return

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box("rules cover", {width = ui.fill(), height = ui.fill(), position = {0, 0}, flags = {.Floating, .Clickable}})
	is_closing := (ui.signal(cover).is_clicked || ui.signal(cover).is_right_clicked) && core.app.frame_count > rules_menu.opened_frame + 1

	if ui.scope(cover) {
		menu := kit.menu_box("rules", rules_menu.position, 300, window_size)

		if ui.scope(menu) {
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 13, font_weight = .Bold, padding = {9, 4, 9, 6}}, "Shuffle")

			hours := shuffle_rules.recent_hours
			hours_text := "Off" if hours == 0 else fmt.tprintf("Past %d h", hours)
			if kit.menu_item("recent", "Play recent songs last", hours_text) {
				choices := RECENT_HOUR_CHOICES
				next := 0
				for choice, index in choices {
					if choice == hours {
						next = (index + 1) % len(choices)
					}
				}
				shuffle_rules.recent_hours = choices[next]
				save_shuffle_rules()
			}
			if kit.menu_item("skipped", "Play often-skipped songs last", "●" if shuffle_rules.skipped_go_last else "○") {
				shuffle_rules.skipped_go_last = !shuffle_rules.skipped_go_last
				save_shuffle_rules()
			}
			if kit.menu_item("albums", "Spread out songs from one album", "●" if shuffle_rules.albums_apart else "○") {
				shuffle_rules.albums_apart = !shuffle_rules.albums_apart
				save_shuffle_rules()
			}
			if kit.menu_item("favourites", "Play favourites earlier", "●" if shuffle_rules.favourites_first else "○") {
				shuffle_rules.favourites_first = !shuffle_rules.favourites_first
				save_shuffle_rules()
			}

			kit.menu_separator()
			ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 11.5, padding = {9, 4, 9, 4}, flags = {.Wrap_Text}}, "onlymuse counts plays and skips itself. Changes apply the next time you shuffle.")
		}
	}

	if is_closing do rules_menu.is_open = false
}
