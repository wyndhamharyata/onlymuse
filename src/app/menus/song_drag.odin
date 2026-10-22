package menus

import "om:app/core"
import "om:app/kit"
import "om:platform"
import "om:ui"

// A press that moves this far becomes a drag.
DRAG_START_POINTS :: 6

@(private = "file")
drag: struct {
	is_dragging: bool,
	song:        core.Catalog_Song,
	// The frame a drag ended, so the row under the release does not take it as a click.
	ended_frame: int,
}

// A row reports its signal each frame. Returns true when the row was clicked, and not dragged.
track_song_row :: proc(signal: ui.Signal, song: core.Catalog_Song) -> bool {
	if signal.is_right_clicked do open_song_menu(song, ui.mouse_position())

	press, is_down := ui.press_position()
	moved := ui.mouse_position() - press
	if signal.is_held &&
	   is_down &&
	   !drag.is_dragging &&
	   moved.x * moved.x + moved.y * moved.y > DRAG_START_POINTS * DRAG_START_POINTS &&
	   song.id != "" {
		drag = {
			is_dragging = true,
			song        = core.copy_song(song),
		}
	}

	return signal.is_clicked && drag.ended_frame != core.app.frame_count
}

// A sidebar playlist under a dragged song lights up, and takes it on release.
take_song_drop :: proc(
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

// The song's name follows the pointer while it is dragged.
build_drag_ghost :: proc() {
	if !drag.is_dragging do return

	if is_mouse_released() {
		core.delete_song(drag.song)
		drag = {
			ended_frame = core.app.frame_count,
		}
		return
	}

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
			background = kit.to_color(0x2c2c31f0),
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
				font_size = 12.5,
			},
			drag.song.name,
		)
	}
	platform.request_frame()
}
