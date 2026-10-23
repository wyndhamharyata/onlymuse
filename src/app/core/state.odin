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
	accent:            [4]f32,
	system_accent:     [4]f32,
	now_playing:       helper.Now_Playing,
	panel:             Panel,
	last_panel:        Panel,
	is_sign_in_needed: bool,
	test_typing:       string,
	started_at:        time.Tick,
	is_sign_in_open:   bool,
	last_frame:        time.Tick,
	capture_path:      string,
	capture_time:      time.Tick,
	frame_count:       int,
	is_bench:          bool,
	is_showing_frames: bool,
	bench_frame_count: int,
	bench_direction:   f32,
	build_durations:   [dynamic]time.Duration,
	frame_starts:      [dynamic]time.Tick,
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
