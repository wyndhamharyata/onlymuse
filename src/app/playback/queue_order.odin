package playback

import "om:app/core"
import "om:app/matching"
import "om:helper"
import "om:youtube"

@(private = "file")
list_play_order :: proc(songs: []core.Catalog_Song, first_index: int) -> []core.Catalog_Song {
	others := make([dynamic]core.Catalog_Song, context.temp_allocator)
	for song, index in songs do if index != first_index do append(&others, song)

	shuffled := shuffle_by_rules(others[:])
	defer delete(shuffled)

	order := make([]core.Catalog_Song, len(songs))
	order[0] = core.copy_song(songs[first_index])
	for song, index in shuffled do order[index + 1] = core.copy_song(song)

	return order
}

@(private = "file")
replace_songs :: proc(songs, original_songs: []core.Catalog_Song) {
	retire_songs(queue.songs)
	retire_songs(queue.original_songs)
	queue.songs = songs
	queue.original_songs = original_songs
}

@(private = "file")
copy_songs :: proc(songs: []core.Catalog_Song) -> []core.Catalog_Song {
	copied := make([]core.Catalog_Song, len(songs))
	for song, index in songs do copied[index] = core.copy_song(song)

	return copied
}

@(private = "file")
make_list_with_song :: proc(
	songs: []core.Catalog_Song,
	index: int,
	song: core.Catalog_Song,
) -> []core.Catalog_Song {
	list := make([]core.Catalog_Song, len(songs) + 1)
	copy(list[:index], songs[:index])
	list[index] = song
	copy(list[index + 1:], songs[index:])

	return list
}

@(private = "file")
retire_songs :: proc(songs: []core.Catalog_Song) {
	for song in songs do retire_song(song)
	append(&retired.lists, songs)
}

@(private = "file")
retired: struct {
	songs: [dynamic]core.Catalog_Song,
	lists: [dynamic][]core.Catalog_Song,
}

@(private)
retire_song :: proc(song: core.Catalog_Song) {
	append(&retired.songs, song)
}

free_retired_songs :: proc() {
	for song in retired.songs do core.delete_song(song)
	for list in retired.lists do delete(list)
	clear(&retired.songs)
	clear(&retired.lists)
}

@(private)
set_playable :: proc(index: int) {
	playable := matching.watch_playable(queue.songs[index])
	if playable.id == queue.songs[index].id do return

	cloned := core.copy_song(playable)
	retire_song(queue.songs[index])
	queue.songs[index] = cloned
}

MATCHED_AHEAD_COUNT :: 25

@(private)
start_matches :: proc() {
	if queue.index < 0 do return

	ahead := queue.songs[queue.index:min(len(queue.songs), queue.index + MATCHED_AHEAD_COUNT)]
	for song in ahead do if youtube.is_song_id(song.id) do _, _ = matching.watch_match(song)
}

play_songs :: proc(songs: []core.Catalog_Song, index: int) {
	if len(songs) == 0 do return

	if !queue.is_shuffled {
		replace_songs(copy_songs(songs), copy_songs(songs))
		play_queue_at(index)
		return
	}

	replace_songs(list_play_order(songs, index), copy_songs(songs))
	play_queue_at(0)
}

shuffle_songs :: proc(songs: []core.Catalog_Song) {
	if len(songs) == 0 do return

	shuffled := shuffle_by_rules(songs)
	defer delete(shuffled)

	replace_songs(copy_songs(shuffled), copy_songs(songs))
	queue.is_shuffled = true
	play_queue_at(0)
}

play_next :: proc(song: core.Catalog_Song) {
	if !has_current_song() {
		play_songs([]core.Catalog_Song{song}, 0)
		core.delete_song(song)
		return
	}

	after := queue.index + 1
	is_same_order := !queue.is_shuffled && len(queue.original_songs) == len(queue.songs)
	original_after := after if is_same_order else len(queue.original_songs)
	songs := make_list_with_song(queue.songs, after, song)
	original := make_list_with_song(queue.original_songs, original_after, core.copy_song(song))

	append(&retired.lists, queue.songs, queue.original_songs)
	queue.songs = songs
	queue.original_songs = original

	save_queue_and_handoff()
}

@(private = "file")
has_current_song :: proc() -> bool {
	return queue.index >= 0 && queue.index < len(queue.songs)
}

remove_from_queue :: proc(index: int) {
	if index == queue.index do return

	removed := queue.songs[index]
	retire_song(removed)
	ordered_remove_slice(&queue.songs, index)

	for song, original_index in queue.original_songs {
		if !matching.is_same_queue_song(removed, song) do continue

		retire_song(song)
		ordered_remove_slice(&queue.original_songs, original_index)
		break
	}

	if index < queue.index do queue.index -= 1
	save_queue_and_handoff()
}

@(private = "file")
ordered_remove_slice :: proc(songs: ^[]core.Catalog_Song, index: int) {
	copy(songs[index:], songs[index + 1:])
	songs^ = songs[:len(songs) - 1]
}

toggle_shuffle :: proc() {
	if !has_current_song() {
		queue.is_shuffled = !queue.is_shuffled
		save_queue_and_handoff()
		return
	}

	// queue.songs may hold Apple's match where the original list holds the YouTube song.
	current := queue.songs[queue.index]
	original_index := 0

	for song, index in queue.original_songs {
		if matching.is_same_queue_song(current, song) {
			original_index = index
			break
		}
	}

	if queue.is_shuffled {
		queue.is_shuffled = false
		retire_songs(queue.songs)
		queue.songs = copy_songs(queue.original_songs)
		queue.index = original_index
		save_queue_and_handoff()
		return
	}

	retire_songs(queue.songs)
	queue.songs = list_play_order(queue.original_songs, original_index)
	queue.index = 0
	queue.is_shuffled = true
	save_queue_and_handoff()
}

cycle_repeat :: proc() {
	switch queue.repeat {
	case "off":
		queue.repeat = "all"
	case "all":
		queue.repeat = "one"
	case:
		queue.repeat = "off"
	}

	save_queue_and_handoff()
}

@(private)
is_queue_leading :: proc() -> bool {
	now_playing := core.app.now_playing
	has_song := helper.has_song(now_playing)
	playing_id := now_playing.song.persistent_id if has_song else ""

	return queue.is_adding || (playing_id != "" && playing_id == queue.playing_persistent_id)
}

skip_to_next :: proc() {
	if !is_queue_leading() {
		helper.send_next()
		return
	}

	if next := find_next_index(); next >= 0 do play_queue_at(next)
}

skip_to_previous :: proc(position_seconds: f64) {
	is_restart := position_seconds > RESTART_AFTER_SECONDS || queue.index == 0

	if !is_queue_leading() {
		helper.send_previous()
		return
	}

	if is_restart {
		helper.send_seek(0)
		return
	}

	play_queue_at(queue.index - 1)
}
