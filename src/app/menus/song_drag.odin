package menus

import "om:app/core"
import "om:app/look"
import "thor:app"
import "thor:kit"
import "thor:platform"
import "thor:ui"

DRAG_START :: 6

@(private = "file")
drag: struct {
	is_dragging: bool,
	song:        core.Catalog_Song,
	ended_frame: int,
}

apply_song_row_signal :: proc(signal: ui.Signal, song: core.Catalog_Song) -> bool {
	if signal.is_secondary do open_song_menu(song, ui.pointer_pos())

	moved := signal.drag
	has_moved := moved.x * moved.x + moved.y * moved.y > DRAG_START * DRAG_START
	can_start_drag := signal.is_held && !drag.is_dragging && song.id != ""

	if can_start_drag && has_moved {
		drag = {
			is_dragging = true,
			song        = core.copy_song(song),
		}
	}
	// The pressed row's cursor shows until the release, wherever the song is dragged.
	if drag.is_dragging && signal.is_held do signal.box.style.cursor = .Closed_Hand

	return signal.is_activated && drag.ended_frame != app.frame_count
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
		ended_frame = app.frame_count,
	}
}

build_drag_ghost :: proc() {
	if !drag.is_dragging do return

	mouse := ui.pointer_pos()
	ghost := ui.box(
		"drag_ghost",
		{
			width = ui.fit_children(),
			height = ui.points(30),
			axis = .X,
			align = .Center,
			gap = 7,
			padding = {10, 0, 12, 0},
			corner_radius = 8,
			bg = look.colors.drag_ghost,
			border_width = 1,
			border_color = {kit.colors.primary.r, kit.colors.primary.g, kit.colors.primary.b, 0.6},
			pos = mouse + {12, 8},
			flags = {.Floating},
		},
	)

	if ui.scope(ghost) {
		kit.icon_box("music.note", 12, kit.colors.primary)
		ui.box(
			"",
			{
				width = ui.fit_text(),
				height = ui.fit_text(),
				text_color = kit.colors.base_content,
				font_size = kit.SMALL_TEXT_SIZE,
			},
			drag.song.name,
		)
	}

	ui.request_frame()
}
