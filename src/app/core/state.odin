package core

import "om:helper"
import "om:store"

Panel :: enum {
	None,
	Lyrics,
	Up_Next,
}

app: struct {
	system_accent:     [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	last_panel:        Panel,
	is_sign_in_needed: bool,
	drives_music_app:  bool,
	preloads_next:     bool,
	is_sign_in_open:   bool,
}

saved_panels := [Panel]string {
	.None    = "null",
	.Lyrics  = `"lyrics"`,
	.Up_Next = `"queue"`,
}

set_panel :: proc(panel: Panel) {
	app.panel = panel
	if panel != .None do app.last_panel = panel
	store.save_state("panel", saved_panels[panel])
}

start_player_mode :: proc() {
	text, ok := store.find_state("drivesMusicApp", context.temp_allocator)
	app.drives_music_app = ok && text == "true"
	helper.send_set_player(app.drives_music_app)

	preloads, has_preloads := store.find_state("preloadsNext", context.temp_allocator)
	app.preloads_next = !has_preloads || preloads != "false"
}

set_preloading :: proc(is_on: bool) {
	app.preloads_next = is_on
	store.save_state("preloadsNext", "true" if is_on else "false")
}

set_player_mode :: proc(is_driving_music_app: bool) {
	app.drives_music_app = is_driving_music_app
	helper.send_set_player(is_driving_music_app)
	store.save_state("drivesMusicApp", "true" if is_driving_music_app else "false")
}
