package playback

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:store"
import "om:ui"

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

	if len(kept) > 0 {
		copy(shuffled, kept[:])
		copy(shuffled[len(kept):], later[:])
	}

	apart_count := 0

	if shuffle_rules.is_album_spread {
		apart_count =
			keep_albums_apart(shuffled[:len(kept)]) + keep_albums_apart(shuffled[len(kept):])
	}

	set_shuffle_note(recent_count, skipped_count, apart_count)

	return shuffled
}

// A song started in Music.app has no catalog ID. \x1f, the ASCII unit separator, is in no name.
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

	cover := ui.box(
		"rules cover",
		{
			width = ui.fill(),
			height = ui.fill(),
			position = {0, 0},
			flags = {.Floating, .Clickable},
		},
	)

	is_closing :=
		(ui.signal(cover).is_clicked || ui.signal(cover).is_right_clicked) &&
		core.app.frame_count > rules_menu.opened_frame + 1

	if ui.scope(cover) {
		menu := kit.menu_box("rules", rules_menu.position, 300, window_size)

		if ui.scope(menu) {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.text,
					font_size = 13,
					font_weight = .Bold,
					padding = {9, 4, 9, 6},
				},
				"Shuffle",
			)

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

			Toggle :: struct {
				id, label: string,
				is_on:     ^bool,
			}
			toggles := []Toggle {
				{"skipped", "Play often-skipped songs last", &shuffle_rules.is_skipped_last},
				{"albums", "Spread out songs from one album", &shuffle_rules.is_album_spread},
				{"favourites", "Play favourites earlier", &shuffle_rules.is_favourite_early},
			}

			for toggle in toggles {
				if kit.menu_item(toggle.id, toggle.label, "●" if toggle.is_on^ else "○") {
					toggle.is_on^ = !toggle.is_on^
					save_shuffle_rules()
				}
			}

			kit.menu_separator()
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
					font_size = 11.5,
					padding = {9, 4, 9, 4},
					flags = {.Wrap_Text},
				},
				"onlymuse counts plays and skips itself. Changes apply the next time you shuffle.",
			)
		}
	}

	if is_closing do rules_menu.is_open = false
}
