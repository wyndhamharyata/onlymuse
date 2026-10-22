package playback

import "om:app/core"
import "om:app/matching"
import "om:helper"
import "om:youtube"

// The shuffle rules in shuffle.odin order it.
@(private = "file")
to_shuffled :: proc(songs: []core.Catalog_Song) -> []core.Catalog_Song {
	return shuffle_by_rules(songs)
}

// With shuffle on, the chosen song plays first and the others follow in a random order. The songs are copies.
@(private = "file")
to_play_order :: proc(songs: []core.Catalog_Song, first_index: int) -> []core.Catalog_Song {
	others := make([dynamic]core.Catalog_Song, context.temp_allocator)
	for song, index in songs do if index != first_index do append(&others, song)

	shuffled := to_shuffled(others[:])
	defer delete(shuffled)

	order := make([]core.Catalog_Song, len(songs))
	order[0] = core.copy_song(songs[first_index])
	for song, index in shuffled do order[index + 1] = core.copy_song(song)

	return order
}

// The queue owns its songs, text and all. A page's songs live in the page's memory, which is read again into
// new memory whenever its answers or its phase change, so a queue that pointed there would read freed memory.
@(private = "file")
replace_songs :: proc(songs, original_songs: []core.Catalog_Song) {
	delete_songs(queue.songs)
	delete_songs(queue.original_songs)
	queue.songs = songs
	queue.original_songs = original_songs
}

@(private = "file")
clone_songs :: proc(songs: []core.Catalog_Song) -> []core.Catalog_Song {
	cloned := make([]core.Catalog_Song, len(songs))
	for song, index in songs do cloned[index] = core.copy_song(song)

	return cloned
}

@(private = "file")
delete_songs :: proc(songs: []core.Catalog_Song) {
	for song in songs do retire_song(song)
	append(&retired.lists, songs)
}

// Songs and lists the queue let go of, freed when the next frame starts, as Up Next and the player may
// already show them in this one. See free_retired_memory.
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

// A YouTube song whose Apple song is known plays from Apple Music, and a copy of Apple's song takes its place.
@(private)
set_playable :: proc(index: int) {
	playable := matching.to_playable(queue.songs[index])
	if playable.id == queue.songs[index].id do return

	cloned := core.copy_song(playable)
	retire_song(queue.songs[index])
	queue.songs[index] = cloned
}

// The queue's next YouTube songs are checked against Apple's catalog now, so they play from Apple when their
// turn comes. Each later one is checked when it is next.
MATCHED_AHEAD_COUNT :: 25

@(private)
start_matches :: proc() {
	if queue.index < 0 do return

	ahead := queue.songs[queue.index:min(len(queue.songs), queue.index + MATCHED_AHEAD_COUNT)]
	for song in ahead do if youtube.is_song_id(song.id) do matching.find_match(song)
}

play_songs :: proc(songs: []core.Catalog_Song, index: int) {
	if len(songs) == 0 do return

	if !queue.is_shuffled {
		replace_songs(clone_songs(songs), clone_songs(songs))
		play_at(index)
		return
	}

	replace_songs(to_play_order(songs, index), clone_songs(songs))
	play_at(0)
}

shuffle_songs :: proc(songs: []core.Catalog_Song) {
	if len(songs) == 0 do return

	shuffled := to_shuffled(songs)
	defer delete(shuffled)

	replace_songs(clone_songs(shuffled), clone_songs(songs))
	queue.is_shuffled = true
	play_at(0)
}

// Puts the song right after the one playing. With nothing queued, it plays now. The queue takes song, a copy.
play_next :: proc(song: core.Catalog_Song) {
	if queue.index < 0 || len(queue.songs) == 0 {
		play_songs([]core.Catalog_Song{song}, 0)
		return
	}

	after := queue.index + 1
	songs := make([]core.Catalog_Song, len(queue.songs) + 1)
	copy(songs[:after], queue.songs[:after])
	songs[after] = song
	copy(songs[after + 1:], queue.songs[after:])

	original := make([]core.Catalog_Song, len(queue.original_songs) + 1)
	copy(original, queue.original_songs)
	original[len(original) - 1] = core.copy_song(song)

	// The new lists hold the old songs themselves, so only the old lists go.
	append(&retired.lists, queue.songs, queue.original_songs)
	queue.songs = songs
	queue.original_songs = original

	sync_handoff()
	save_queue()
}

play_queue_at :: proc(index: int) {
	play_at(index)
}

remove_from_queue :: proc(index: int) {
	if index == queue.index do return

	// A retired song's text stays readable until the next frame.
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
	set_queue()
}

@(private = "file")
ordered_remove_slice :: proc(songs: ^[]core.Catalog_Song, index: int) {
	copy(songs[index:], songs[index + 1:])
	songs^ = songs[:len(songs) - 1]
}

toggle_shuffle :: proc() {
	if queue.index < 0 || queue.index >= len(queue.songs) {
		queue.is_shuffled = !queue.is_shuffled
		set_queue()
		return
	}

	// The queue may hold Apple's match of a YouTube song in the original list.
	current := queue.songs[queue.index]
	original_index := 0

	for song, index in queue.original_songs {
		if matching.is_same_queue_song(current, song) {
			original_index = index
		}
	}

	if queue.is_shuffled {
		queue.is_shuffled = false
		delete_songs(queue.songs)
		queue.songs = clone_songs(queue.original_songs)
		queue.index = original_index
		set_queue()
		return
	}

	delete_songs(queue.songs)
	queue.songs = to_play_order(queue.original_songs, original_index)
	queue.index = 0
	queue.is_shuffled = true
	set_queue()
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

	set_queue()
}

// The queue leads only while Music.app plays the song it started. Otherwise Music.app's own order applies.
@(private)
is_queue_leading :: proc() -> bool {
	now_playing := core.app.now_playing
	has_song := now_playing.playback == .Playing || now_playing.playback == .Paused
	playing_id := now_playing.song.persistent_id if has_song else ""

	return queue.is_adding || (playing_id != "" && playing_id == queue.playing_persistent_id)
}

skip_to_next :: proc() {
	if !is_queue_leading() {
		helper.send(`{"type":"next"}`)
		return
	}

	if next := find_next_index(); next >= 0 do play_at(next)
}

skip_to_previous :: proc(position_seconds: f64) {
	if !is_queue_leading() {
		helper.send(`{"type":"previous"}`)
		return
	}

	if position_seconds > RESTART_AFTER_SECONDS || queue.index == 0 {
		helper.send(`{"type":"seek","positionSeconds":0}`)
		return
	}

	play_at(queue.index - 1)
}
