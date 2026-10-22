// What every part of the window shares: app state, navigation, page data, songs, library lists.
// It imports no other package of the window, so any of them can import it.
package core

import "core:time"
import "om:helper"
import "om:platform"
import "om:store"

Panel :: enum {
	None,
	Lyrics,
	Up_Next,
}

app: struct {
	window:            ^platform.Window,
	zoom:              f32,
	// The colour of the playing song's cover, or system_accent when the cover has none to give.
	accent:            [4]f32,
	// The accent chosen in System Settings, as the helper reports it.
	system_accent:     [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	// The tab the panel opens on.
	last_panel:        Panel,
	is_sign_in_needed: bool,
	// OM_TYPE types this text into the focused field a second after the start, for the tests.
	test_typing:       string,
	started_at:        time.Tick,
	is_sign_in_open:   bool,
	last_frame:        time.Tick,
	// For the tests, OM_CAPTURE saves a frame here and quits. OM_CAPTURE_SECONDS waits first.
	capture_path:      string,
	capture_time:      time.Tick,
	frame_count:       int,
	is_bench:          bool,
	// OM_FRAMES=1 shows how long each frame takes to build.
	is_showing_frames: bool,
	bench_frame_count: int,
	bench_direction:   f32,
	build_durations:   [dynamic]time.Duration,
	frame_starts:      [dynamic]time.Tick,
}

// Opens the panel on the tab it last showed, or closes it.
toggle_side_panel :: proc() {
	set_panel(.None if app.panel != .None else app.last_panel)
}

set_panel :: proc(panel: Panel) {
	app.panel = panel
	if panel != .None do app.last_panel = panel

	saved := [Panel]string {
		.None    = "null",
		.Lyrics  = `"lyrics"`,
		.Up_Next = `"queue"`,
	}

	store.save_state("panel", saved[panel])
}
