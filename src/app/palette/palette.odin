package palette

import "core:mem/virtual"
import "om:app/core"
import "om:app/lists"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "thor:kit"
import "thor:ui"

PALETTE_WIDTH :: 560

PALETTE_ROW_HEIGHT :: 36

PALETTE_LIST_MAX_HEIGHT :: 420

PALETTE_SETTLE_MS :: 300

MAX_GROUP_RESULT_COUNT :: 5

PALETTE_FIELD_HEIGHT :: 40

PALETTE_FIELD_FONT_SIZE :: 16

@(private)
Palette_Action :: enum {
	Navigate,
	Play_Library_Song,
	Play_Song,
	Open_Card,
	Play_Pause,
	Next,
	Previous,
	Shuffle_All,
	Toggle_Player,
	Favourite,
	Show_Lyrics,
	Show_Up_Next,
}

@(private)
Palette_Result :: struct {
	group:       string,
	title:       string,
	subtitle:    string,
	symbol:      string,
	artwork:     apple.Artwork,
	is_round:    bool,
	shortcut:    string,
	is_disabled: bool,
	action:      Palette_Action,
	page:        core.Page,
	song:        core.Catalog_Song,
	card:        apple.Card,
	index:       int,
}

@(private)
palette: struct {
	is_open:             bool,
	field:               kit.Text_Input,
	selected_index:      int,
	arena:               virtual.Arena,
	results:             []Palette_Result,
	built_term:          string,
	built_signature:     int,
	typed_at_ms:         f64,
	last_mouse_pos:      [2]f32,
	should_reset_scroll: bool,
}

start_palette :: proc() {
	palette.field.is_keeping_focus = true
	palette.field.is_taking_up_down = true
}

toggle_palette :: proc() {
	if palette.is_open {
		close_palette()
		return
	}

	palette.is_open = true
	palette.selected_index = 0
	palette.built_signature = -1
	palette.should_reset_scroll = true
	kit.set_input_text(&palette.field, "")
	kit.focus_input(&palette.field)
}

open_palette_for_test :: proc(term: string) {
	toggle_palette()
	kit.set_input_text(&palette.field, term)
}

@(private = "file")
close_palette :: proc() {
	palette.is_open = false
	palette.field.is_focused = false
}

build_palette :: proc() {
	if !palette.is_open {
		// kit's dialog closes it on Escape or a press outside, so the field lets go of the keyboard here.
		if palette.field.is_focused do close_palette()
		return
	}

	field := &palette.field

	if field.is_cancelled {
		close_palette()
		return
	}

	if field.is_changed {
		palette.typed_at_ms = helper.now_ms()
		palette.selected_index = 0
		palette.should_reset_scroll = true
	}

	watch_results()

	result_count := len(palette.results)

	if result_count > 0 {
		palette.selected_index =
			(palette.selected_index + field.step + result_count) % result_count
	}

	if field.is_submitted &&
	   result_count > 0 &&
	   !palette.results[palette.selected_index].is_disabled {
		run_result(palette.results[palette.selected_index])
		close_palette()
		return
	}

	picked := -1
	width := min(PALETTE_WIDTH, ui.window_size().x - 40)

	if kit.palette_dialog("palette", &palette.is_open, width) {
		kit.text_field(
			"palette_field",
			field,
			"Go to a page, an artist, a song, or do something",
			"magnifyingglass",
			variant = .Ghost,
			style = {
				height = ui.points(PALETTE_FIELD_HEIGHT),
				font_size = PALETTE_FIELD_FONT_SIZE,
				flags = {.Tab_As_Arrows},
			},
		)
		picked = build_results()
	}

	palette.last_mouse_pos = ui.pointer_pos()

	if picked >= 0 {
		run_result(palette.results[picked])
		close_palette()
	}
}

@(private = "file")
run_result :: proc(result: Palette_Result) {
	if result.is_disabled do return

	switch result.action {
	case .Navigate:
		core.navigate(result.page)
	case .Play_Library_Song:
		songs, _, _ := core.watch_library_songs()
		if result.index < len(songs) do playback.play_songs(songs, result.index)
	case .Play_Song:
		playback.play_songs([]core.Catalog_Song{result.song}, 0)
	case .Open_Card:
		lists.open_card([]apple.Card{result.card}, 0)
	case .Play_Pause:
		helper.send_play_pause()
	case .Next:
		playback.skip_to_next()
	case .Previous:
		playback.skip_to_prev(helper.read_pos_seconds(core.app.now_playing))
	case .Shuffle_All:
		songs, _, _ := core.watch_library_songs()
		playback.shuffle_songs(songs)
	case .Toggle_Player:
		core.set_player_mode(!core.app.drives_music_app)
	case .Favourite:
		if song, persistent_id, ok := playback.find_playing_song(); ok {
			playback.toggle_favourite(song, persistent_id)
		}
	case .Show_Lyrics:
		core.set_panel(.Lyrics)
	case .Show_Up_Next:
		core.set_panel(.Up_Next)
	}
}
