package playback

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:store"
import "thor:kit"
import "thor:ui"

OFTEN_SKIPPED_COUNT :: 3

FAVOURITE_WEIGHT :: 2.5

RECENT_HOUR_CHOICES :: [?]int{0, 2, 6, 24}

Shuffle_Rules :: struct {
	recent_hours:       int `json:"recentHours"`,
	is_skipped_last:    bool `json:"skippedGoLast"`,
	is_album_spread:    bool `json:"albumsApart"`,
	is_favourite_early: bool `json:"favouritesFirst"`,
}

shuffle_rules := Shuffle_Rules {
	recent_hours    = 6,
	is_skipped_last = true,
	is_album_spread = true,
}

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

shuffle_by_rules :: proc(songs: []core.Catalog_Song) -> []core.Catalog_Song {
	shuffled := make([]core.Catalog_Song, len(songs))
	copy(shuffled, songs)

	if shuffle_rules.is_favourite_early {
		// Each song draws u^(1/weight). The largest keys go first, after Efraimidis and Spirakis.
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

	recent, skipped := list_song_history()
	recent_count, skipped_count := 0, 0
	kept := make([dynamic]core.Catalog_Song, context.temp_allocator)
	later := make([dynamic]core.Catalog_Song, context.temp_allocator)

	for song in shuffled {
		key := to_song_key(song.name, song.artist_name)

		switch {
		case shuffle_rules.recent_hours > 0 && recent[key]:
			recent_count += 1
			append(&later, song)
		case shuffle_rules.is_skipped_last && skipped[key]:
			skipped_count += 1
			append(&later, song)
		case:
			append(&kept, song)
		}
	}

	copy(shuffled, kept[:])
	copy(shuffled[len(kept):], later[:])

	apart_count := 0

	if shuffle_rules.is_album_spread {
		apart_count =
			keep_albums_apart(shuffled[:len(kept)]) + keep_albums_apart(shuffled[len(kept):])
	}

	set_shuffle_note(recent_count, skipped_count, apart_count)

	return shuffled
}

// A song started in Music.app has no catalog ID. No name holds \x1f, the ASCII unit separator.
@(private = "file")
to_song_key :: proc(name, artist: string) -> string {
	return fmt.tprintf("%s\x1f%s", name, artist)
}

@(private = "file")
list_song_history :: proc() -> (recent, skipped: map[string]bool) {
	recent = make(map[string]bool, context.temp_allocator)
	skipped = make(map[string]bool, context.temp_allocator)
	since_ms := core.now_ms() - i64(shuffle_rules.recent_hours) * core.HOUR_MS
	play_counts := make(map[string]int, context.temp_allocator)
	skip_counts := make(map[string]int, context.temp_allocator)

	for play in play_log {
		key := to_song_key(play.name, play.artist)

		if play.is_skip {
			skip_counts[key] += 1
		} else {
			play_counts[key] += 1
			if play.played_at_ms >= since_ms do recent[key] = true
		}
	}

	for key, count in skip_counts {
		is_often_skipped := count >= OFTEN_SKIPPED_COUNT && count > play_counts[key]
		if is_often_skipped do skipped[key] = true
	}

	return
}

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
	parts := make([dynamic]string, context.temp_allocator)

	if recent_count > 0 {
		append(
			&parts,
			fmt.tprintf("%d recent %s", recent_count, "song" if recent_count == 1 else "songs"),
		)
	}

	if skipped_count > 0 {
		append(
			&parts,
			fmt.tprintf(
				"%d often-skipped %s",
				skipped_count,
				"song" if skipped_count == 1 else "songs",
			),
		)
	}

	note := ""

	if len(parts) > 0 {
		note = fmt.tprintf(
			"%s %s last.",
			strings.join(parts[:], " and ", context.temp_allocator),
			"plays" if recent_count + skipped_count == 1 else "play",
		)
	}

	if apart_count > 0 {
		note = fmt.tprintf(
			"%s%sSongs from one album don't play back to back.",
			note,
			" " if note != "" else "",
		)
	}

	delete(shuffle_note)
	shuffle_note = strings.clone(note)
}

RULES_MENU_WIDTH :: 300

RULES_GROUP_GAP :: 12

RULES_LABEL_GAP :: 4

RULES_TOGGLE_GAP :: 8

RECENT_OPTIONS := []kit.Option {
	{id = "0", label = "Off"},
	{id = "2", label = "2 h"},
	{id = "6", label = "6 h"},
	{id = "24", label = "24 h"},
}

@(private = "file")
rules_menu: struct {
	is_open: bool,
	pos:     [2]f32,
}

// pos is a point by the control that opens the rules. They open below it, or above it with no room below.
open_shuffle_rules :: proc(pos: [2]f32) {
	rules_menu = {true, pos}
}

build_shuffle_rules :: proc() {
	if kit.popover("shuffle_rules", &rules_menu.is_open, rules_menu.pos, width = ui.points(RULES_MENU_WIDTH)) {
		// With the popover's own 5, its content sits 14 points in on every side, as menu items' labels do.
		if ui.col("rules", {width = ui.fill(), gap = RULES_GROUP_GAP, padding = 9}) {
			kit.heading("Shuffle", .Small)

			if ui.col("recent", {width = ui.fill(), gap = RULES_LABEL_GAP}) {
				kit.text("Play recent songs last")
				build_recent_hours()
			}

			if ui.col("toggles", {width = ui.fill(), gap = RULES_TOGGLE_GAP}) {
				build_rule_toggle("skipped", "Play often-skipped songs last", &shuffle_rules.is_skipped_last)
				build_rule_toggle("albums", "Spread out songs from one album", &shuffle_rules.is_album_spread)
				build_rule_toggle("favourites", "Play favourites earlier", &shuffle_rules.is_favourite_early)
			}
		}
	}
}

@(private = "file")
build_recent_hours :: proc() {
	choices := RECENT_HOUR_CHOICES
	selected := RECENT_OPTIONS[0].id

	for choice, index in choices {
		if choice == shuffle_rules.recent_hours do selected = RECENT_OPTIONS[index].id
	}

	if !kit.segmented("recent", &selected, RECENT_OPTIONS, width = ui.fill()).is_changed do return

	for option, index in RECENT_OPTIONS {
		if option.id == selected do shuffle_rules.recent_hours = choices[index]
	}

	save_shuffle_rules()
}

@(private = "file")
build_rule_toggle :: proc(id, label: string, is_on: ^bool) {
	if ui.row(id, {width = ui.fill(), align = .Center, gap = 10}) {
		kit.text(label)
		if kit.toggle("switch", is_on, label, is_label_hidden = true).is_changed do save_shuffle_rules()
	}
}
