package menus

import "om:app/core"
import "om:app/kit"
import "om:platform"
import "om:ui"

DRAG_START_POINTS :: 6

@(private = "file")
drag: struct {
	is_dragging: bool,
	song:        core.Catalog_Song,
	ended_frame: int,
}

apply_song_row_signal :: proc(signal: ui.Signal, song: core.Catalog_Song) -> bool {
	if signal.is_right_clicked do open_song_menu(song, ui.mouse_position())

	press, is_down := ui.press_position()
	moved := ui.mouse_position() - press
	has_moved := moved.x * moved.x + moved.y * moved.y > DRAG_START_POINTS * DRAG_START_POINTS
	can_start_drag := signal.is_held && is_down && !drag.is_dragging && song.id != ""

	if can_start_drag && has_moved {
		drag = {
			is_dragging = true,
			song        = core.copy_song(song),
		}
	}

	return signal.is_clicked && drag.ended_frame != core.app.frame_count
}

apply_song_drop :: proc(
	is_hovered: bool,
	playlist_id, playlist_name: string,
	can_edit: bool,
) -> bool {
	if !drag.is_dragging || !is_hovered || !can_edit do return false

	if is_mouse_released() do add_to_playlist(playlist_id, playlist_name, drag.song)

	return true
}

@(private = "file")
is_mouse_released :: proc() -> bool {
	for event in platform.list_events() {
		if release, ok := event.(platform.Mouse_Release); ok && release.button == .Left {
			return true
		}
	}

	return false
}

apply_drag_release :: proc() {
	if !drag.is_dragging || !is_mouse_released() do return

	core.delete_song(drag.song)
	drag = {
		ended_frame = core.app.frame_count,
	}
}

build_drag_ghost :: proc() {
	if !drag.is_dragging do return

	mouse := ui.mouse_position()
	ghost := ui.box(
		"drag ghost",
		{
			width = ui.fit_children(),
			height = ui.points(30),
			axis = .X,
			align = .Center,
			gap = 7,
			padding = {10, 0, 12, 0},
			corner_radius = 8,
			background = kit.colors.drag_ghost,
			border_width = 1,
			border_color = {core.app.accent.r, core.app.accent.g, core.app.accent.b, 0.6},
			position = mouse + {12, 8},
			flags = {.Floating},
		},
	)

	if ui.scope(ghost) {
		kit.icon_box("", "music.note", 12, core.app.accent)
		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = kit.colors.text,
				font_size = kit.SMALL_TEXT_POINTS,
			},
			drag.song.name,
		)
	}

	platform.request_frame()
}
