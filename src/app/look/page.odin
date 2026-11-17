package look

import "om:app/core"
import "om:apple"
import "thor:kit"
import "thor:ui"

page_scroll :: proc(id: string) -> ^ui.Box {
	box := ui.box(
		id,
		{
			width = ui.fill(),
			height = ui.fill(),
			axis = .Y,
			gap = 20,
			padding = {PAGE_PADDING, 0, PAGE_PADDING, PAGE_PADDING},
			flags = {.Scroll, .Clip},
		},
	)
	core.keep_scroll(box)

	return box
}

// The panel's width as it was drawn last frame, the frame a page's size comes from, while it springs open or shut.
panel_width: f32

to_content_width :: proc(page: ^ui.Box) -> f32 {
	return page.size.x - page.style.padding.x - page.style.padding.z
}

to_phase_text :: proc(phase: apple.Phase) -> string {
	return "onlymuse could not reach Apple Music." if phase == .Failed else ""
}

build_phase :: proc(phase: apple.Phase) {
	if phase == .Failed {
		kit.description(to_phase_text(phase))
		return
	}

	build_loading()
}

build_loading :: proc() {
	kit.loading("loading")
}
