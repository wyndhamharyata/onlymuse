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
	// The playing song's cover's colour, or system_accent when it has none to give.
	accent:            [4]f32,
	// The accent chosen in System Settings, as the helper reports it.
	system_accent:     [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	// The tab the panel opens on.
	last_panel:        Panel,
	is_sign_in_needed: bool,
	// OM_TYPE: text typed into the focused field a second in, for the tests.
	test_typing:       string,
	started_at:        time.Tick,
	is_sign_in_open:   bool,
	last_frame:        time.Tick,
	// OM_CAPTURE saves a frame to this file and quits, for the development tests. OM_CAPTURE_SECONDS waits first.
	capture_path:      string,
	capture_time:      time.Tick,
	frame_count:       int,
	is_bench:          bool,
	// OM_FRAMES=1 shows how long each frame took to build.
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
	saved := [Panel]string{.None = "null", .Lyrics = `"lyrics"`, .Up_Next = `"queue"`}
	store.save_state("panel", saved[panel])
}
