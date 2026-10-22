// The command palette, opened with Cmd K.
package palette

import "core:mem/virtual"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:ui"

PALETTE_POINTS :: 560

PALETTE_TOP_POINTS :: 70

PALETTE_ROW_POINTS :: 36

PALETTE_LIST_POINTS :: 420

// The palette asks Apple Music once typing stops for this long, not at each key press.
PALETTE_SETTLE_MS :: 300

// The most results each group shows.
PALETTE_GROUP_LIMIT :: 5

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
	Favourite,
	Show_Lyrics,
	Show_Up_Next,
}

@(private)
Palette_Result :: struct {
	group:    string,
	title:    string,
	subtitle: string,
	symbol:   string,
	artwork:  apple.Artwork,
	is_round: bool,
	shortcut: string,
	action:   Palette_Action,
	page:     core.Page,
	song:     core.Catalog_Song,
	card:     apple.Card,
	// The song's place in the library, for Play_Library_Song.
	index:    int,
}

@(private)
palette: struct {
	is_open:             bool,
	field:               kit.Text_Field,
	selected_index:      int,
	// update_results builds the results again in arena when the term or its data changes.
	arena:               virtual.Arena,
	results:             []Palette_Result,
	built_term:          string,
	built_signature:     int,
	// When the term last changed.
	typed_at_ms:         f64,
	opened_frame:        int,
	last_mouse_position: [2]f32,
}

start_palette :: proc() {
	palette.field.keeps_focus = true
	palette.field.takes_up_down = true
	kit.register_text_field(&palette.field)
}

// Cmd K opens the palette. A second Cmd K closes it.
toggle_palette :: proc() {
	if palette.is_open {
		close_palette()
		return
	}

	palette.is_open = true
	palette.selected_index = 0
	palette.opened_frame = core.app.frame_count
	palette.built_signature = -1
	kit.set_field_text(&palette.field, "")
	kit.focus_field(&palette.field)
}

// OM_PALETTE opens the palette with a term. A test cannot type into a window behind the others.
open_palette_for_test :: proc(term: string) {
	toggle_palette()
	kit.set_field_text(&palette.field, term)
}

@(private = "file")
close_palette :: proc() {
	palette.is_open = false
	palette.field.is_focused = false
}

build_palette :: proc() {
	if !palette.is_open do return

	field := &palette.field

	if field.is_cancelled {
		close_palette()
		return
	}

	if field.is_changed {
		palette.typed_at_ms = helper.now_ms()
		palette.selected_index = 0
	}

	update_results()

	result_count := len(palette.results)
	if result_count > 0 {
		palette.selected_index =
			(palette.selected_index + field.step + result_count) % result_count
	}

	if field.is_submitted && result_count > 0 {
		run_result(palette.results[palette.selected_index])
		close_palette()
		return
	}

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box(
		"palette cover",
		{
			width = ui.fill(),
			height = ui.fill(),
			background = kit.to_color(0x00000059),
			position = {0, 0},
			flags = {.Floating, .Clickable},
		},
	)
	is_closing := ui.signal(cover).is_clicked && core.app.frame_count > palette.opened_frame + 1
	picked := -1

	if ui.scope(cover) {
		width := min(PALETTE_POINTS, window_size.x - 40)
		position := [2]f32{(window_size.x - width) / 2, PALETTE_TOP_POINTS}

		ui.box(
			"palette shadow",
			{
				width = ui.points(width),
				height = ui.points(300),
				corner_radius = 16,
				background = {0, 0, 0, 0.5},
				softness = 40,
				position = position + {0, 16},
				flags = {.Floating},
			},
		)
		panel := ui.box(
			"palette",
			{
				width = ui.points(width),
				height = ui.fit_children(),
				axis = .Y,
				padding = {8, 8, 8, 8},
				gap = 6,
				corner_radius = 14,
				background = kit.to_color(0x26262af5),
				border_width = 1,
				border_color = kit.to_color(0xffffff1f),
				position = position,
				flags = {.Floating, .Clickable},
			},
		)

		if ui.scope(panel) {
			kit.build_text_field(
				field,
				"palette field",
				"Go to a page, an artist, a song, or do something",
				"magnifyingglass",
				40,
				16,
				{0, 0, 0, 0.001},
			)
			picked = build_results()
		}
	}

	palette.last_mouse_position = ui.mouse_position()

	if picked >= 0 {
		run_result(palette.results[picked])
		is_closing = true
	}

	if is_closing do close_palette()
}

@(private = "file")
run_result :: proc(result: Palette_Result) {
	switch result.action {
	// navigate, play_songs and open_card keep their own copies, so the arena may free the results.
	case .Navigate:
		core.navigate(result.page)
	case .Play_Library_Song:
		songs, _, _ := core.list_library_songs()
		if result.index < len(songs) do playback.play_songs(songs, result.index)
	case .Play_Song:
		playback.play_songs([]core.Catalog_Song{result.song}, 0)
	case .Open_Card:
		lists.open_card([]apple.Card{result.card}, 0)
	case .Play_Pause:
		helper.send(`{"type":"playPause"}`)
	case .Next:
		playback.skip_to_next()
	case .Previous:
		playback.skip_to_previous(helper.to_position_seconds(core.app.now_playing))
	case .Shuffle_All:
		songs, _, _ := core.list_library_songs()
		playback.shuffle_songs(songs)
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
