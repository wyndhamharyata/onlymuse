package palette

import "core:mem/virtual"
import "om:app/core"
import "om:app/kit"
import "om:app/lists"
import "om:app/playback"
import "om:apple"
import "om:helper"
import "om:ui"

PALETTE_WIDTH_POINTS :: 560

PALETTE_TOP_POINTS :: 70

PALETTE_ROW_HEIGHT_POINTS :: 36

PALETTE_LIST_MAX_HEIGHT_POINTS :: 420

PALETTE_SETTLE_MS :: 300

MAX_GROUP_RESULT_COUNT :: 5

PALETTE_FIELD_HEIGHT_POINTS :: 40

PALETTE_FIELD_FONT_SIZE :: 16

// kit.build_text_field draws its own field colour when the alpha is 0. This shows the panel's.
PALETTE_FIELD_BACKGROUND :: [4]f32{0, 0, 0, 0.001}

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
	index:    int,
}

@(private)
palette: struct {
	is_open:             bool,
	field:               kit.Text_Field,
	selected_index:      int,
	arena:               virtual.Arena,
	results:             []Palette_Result,
	built_term:          string,
	built_signature:     int,
	typed_at_ms:         f64,
	opened_frame:        int,
	last_mouse_position: [2]f32,
}

start_palette :: proc() {
	palette.field.is_keeping_focus = true
	palette.field.is_taking_up_down = true
	kit.register_text_field(&palette.field)
}

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

	watch_results()

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
		width := min(PALETTE_WIDTH_POINTS, window_size.x - 40)
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
				PALETTE_FIELD_HEIGHT_POINTS,
				PALETTE_FIELD_FONT_SIZE,
				PALETTE_FIELD_BACKGROUND,
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
		playback.skip_to_previous(helper.read_position_seconds(core.app.now_playing))
	case .Shuffle_All:
		songs, _, _ := core.watch_library_songs()
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
