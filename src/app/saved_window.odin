package main

import "om:app/core"
import "om:store"

start_saved_window_state :: proc() {
	core.app.last_panel = .Up_Next

	if saved, has_panel := store.find_state("panel", context.temp_allocator); has_panel {
		for text, panel in core.saved_panels do if text == saved do core.set_panel(panel)
	}
}
