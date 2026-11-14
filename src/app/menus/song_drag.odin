package menus

import "om:app/core"
import "om:app/look"
import "thor:kit"
import "thor:ui"

@(private = "file")
drag: struct {
	is_dragging: bool,
	song:        core.Catalog_Song,
}

apply_song_row_signal :: proc(signal: ui.Signal, song: core.Catalog_Song) -> bool {
	if signal.is_secondary do open_song_menu(song, ui.pointer_pos())

	can_start_drag := signal.is_dragged && !drag.is_dragging && song.id != ""

	if can_start_drag {
		drag = {
			is_dragging = true,
			song        = core.copy_song(song),
		}
	}
	// The pressed row's cursor shows until the release, wherever the song is dragged.
	if drag.is_dragging && signal.is_held do signal.box.style.cursor = .Closed_Hand

	return signal.is_activated
}

// Adds the dragged song to the playlist when it is dropped on its row, and says whether the row shows as
// the drop target now.
apply_song_drop :: proc(
	signal: ui.Signal,
	playlist_id, playlist_name: string,
	can_edit: bool,
) -> bool {
	if !drag.is_dragging || !can_edit do return false

	if signal.is_dropped_on do add_to_playlist(playlist_id, playlist_name, drag.song)

	return signal.is_hovered
}

apply_drag_release :: proc() {
	if !drag.is_dragging || ui.interaction().is_held do return

	core.delete_song(drag.song)
	drag = {}
}

build_drag_ghost :: proc() {
	if !drag.is_dragging do return

	mouse := ui.pointer_pos()
	ghost := ui.box(
		"drag_ghost",
		{
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
				text_color = kit.colors.base_content,
				font_size = kit.SMALL_TEXT_SIZE,
			},
			drag.song.name,
		)
	}

	ui.request_frame()
}
