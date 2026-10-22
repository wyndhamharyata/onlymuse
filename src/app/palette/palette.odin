// The command palette, opened with Cmd K.
package palette

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
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

// Apple Music is searched once typing rests this long, so each key press does not ask Apple.
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
	is_open:      bool,
	field:        kit.Text_Field,
	selected:     int,
	// The results, rebuilt into the arena when the term or the data under it changes.
	arena:        virtual.Arena,
	results:      []Palette_Result,
	built_term:   string,
	built_signature: int,
	// When the term last changed, in ms.
	typed_at:     f64,
	opened_frame: int,
	last_mouse:   [2]f32,
}

start_palette :: proc() {
	palette.field.keeps_focus = true
	palette.field.takes_up_down = true
	kit.register_text_field(&palette.field)
}

// Cmd K opens it, and again closes it.
toggle_palette :: proc() {
	if palette.is_open {
		close_palette()
		return
	}

	palette.is_open = true
	palette.selected = 0
	palette.opened_frame = core.app.frame_count
	palette.built_signature = -1
	kit.set_field_text(&palette.field, "")
	kit.focus_field(&palette.field)
}

// For the tests, which cannot type into a window behind the others: OM_PALETTE opens it with a term.
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
		palette.typed_at = helper.now_ms()
		palette.selected = 0
	}

	update_results()

	count := len(palette.results)
	if count > 0 do palette.selected = (palette.selected + field.step + count) % count

	if field.is_submitted && count > 0 {
		run_result(palette.results[palette.selected])
		close_palette()
		return
	}

	root := ui.current_parent()
	window_size := [2]f32{root.style.width.value, root.style.height.value}
	cover := ui.box("palette cover", {width = ui.fill(), height = ui.fill(), background = kit.to_color(0x00000059), position = {0, 0}, flags = {.Floating, .Clickable}})
	is_closing := ui.signal(cover).is_clicked && core.app.frame_count > palette.opened_frame + 1
	picked := -1

	if ui.scope(cover) {
		width := min(PALETTE_POINTS, window_size.x - 40)
		position := [2]f32{(window_size.x - width) / 2, PALETTE_TOP_POINTS}
		ui.box("palette shadow", {width = ui.points(width), height = ui.points(300), corner_radius = 16, background = {0, 0, 0, 0.5}, softness = 40, position = position + {0, 16}, flags = {.Floating}})
		panel := ui.box("palette", {
			width         = ui.points(width),
			height        = ui.fit_children(),
			axis          = .Y,
			padding       = {8, 8, 8, 8},
			gap           = 6,
			corner_radius = 14,
			background    = kit.to_color(0x26262af5),
			border_width  = 1,
			border_color  = kit.to_color(0xffffff1f),
			position      = position,
			flags         = {.Floating, .Clickable},
		})

		if ui.scope(panel) {
			kit.build_text_field(field, "palette field", "Go to a page, an artist, a song, or do something", "magnifyingglass", 40, 16, {0, 0, 0, 0.001})
			picked = build_results()
		}
	}

	palette.last_mouse = ui.mouse_position()

	if picked >= 0 {
		run_result(palette.results[picked])
		is_closing = true
	}
	if is_closing do close_palette()
}

// Groups with a title each. Returns the index of a clicked result, or -1.
@(private = "file")
build_results :: proc() -> int {
	if len(palette.results) == 0 {
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, padding = {10, 6, 10, 8}}, "Nothing matches. Apple Music is searched as you pause.")
		return -1
	}

	list := ui.box("palette list", {width = ui.fill(), height = ui.points(min(PALETTE_LIST_POINTS, palette_list_height())), axis = .Y, flags = {.Scroll, .Clip}})
	picked := -1

	if ui.scope(list) {
		group := ""
		for result, index in palette.results {
			if result.group != group {
				group = result.group
				ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 11, font_weight = .Bold, padding = {10, 8, 10, 4}}, strings.to_upper(group, context.temp_allocator))
			}
			if build_result_row(result, index) do picked = index
		}
	}

	return picked
}

@(private = "file")
palette_list_height :: proc() -> f32 {
	groups := 0
	group := ""
	for result in palette.results {
		if result.group != group {
			group = result.group
			groups += 1
		}
	}

	return f32(len(palette.results)) * PALETTE_ROW_POINTS + f32(groups) * 27
}

// Returns true when clicked. The pointer over a row selects it.
@(private = "file")
build_result_row :: proc(result: Palette_Result, index: int) -> bool {
	is_selected := index == palette.selected
	row := ui.box(fmt.tprintf("result %d", index), {
		width         = ui.fill(),
		height        = ui.points(PALETTE_ROW_POINTS),
		axis          = .X,
		align         = .Center,
		gap           = 10,
		padding       = {8, 0, 10, 0},
		corner_radius = 8,
		background    = kit.to_accent_tint(core.app.accent) if is_selected else {},
		flags         = {.Clickable},
	})
	signal := ui.signal(row)
	// The pointer selects only when it moves, so a row under a still pointer leaves the arrow keys' choice.
	if signal.is_hovered && ui.mouse_position() != palette.last_mouse do palette.selected = index

	if ui.scope(row) {
		if result.artwork.url != "" {
			kit.artwork_box(apple.to_artwork_url(result.artwork, kit.to_artwork_pixels(26)), 26, 13 if result.is_round else 4, kit.to_placeholder(result.artwork, result.title, "music.note"))
		} else {
			kit.icon_box("", result.symbol if result.symbol != "" else "arrow.right", 14, core.app.accent if is_selected else kit.colors.dim, {width = ui.points(26), height = ui.points(26)})
		}

		ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 13.5, flags = {.Truncate_Text}}, result.title)
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 12, flags = {.Truncate_Text}}, result.subtitle)
		if result.shortcut != "" {
			ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 12}, result.shortcut)
		}
		if is_selected {
			ui.box("", {width = ui.fit_text(), height = ui.fit_text(), text_color = core.app.accent, font_size = 13}, "↵")
		}
	}

	return signal.is_clicked
}

@(private = "file")
run_result :: proc(result: Palette_Result) {
	switch result.action {
	// navigate, play_songs and open_card keep their own copies, so the results' memory can go.
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
		playback.skip_to_previous(helper.position_seconds(core.app.now_playing))
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
