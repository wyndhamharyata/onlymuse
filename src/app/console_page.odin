package app

import "core:fmt"
import "core:strings"
import "core:time"
import "om:app/kit"
import "om:console"
import "om:platform"
import "om:ui"

CONSOLE_TIME_POINTS :: 62

CONSOLE_SOURCE_POINTS :: 62

// Every error and refused request since onlymuse started, newest first.
build_console_page :: proc() {
	entries := console.list()
	count_text := fmt.tprintf("%d %s since onlymuse started", len(entries), "error" if len(entries) == 1 else "errors")
	page := kit.page_scroll("console")

	if ui.scope(page) {
		header := ui.box("header", {width = ui.fill(), height = ui.fit_children(), axis = .X, align = .End, gap = 10})

		if ui.scope(header) {
			heading := ui.box("heading", {width = ui.fill(), height = ui.fit_children(), axis = .Y})

			if ui.scope(heading) {
				kit.page_heading("Console")
				kit.text_box(count_text if len(entries) > 0 else "No errors since onlymuse started.", kit.colors.dim)
			}

			if len(entries) > 0 && kit.action_button("Copy All", "doc.on.doc", false) {
				platform.write_clipboard(to_console_text(entries))
				kit.show_toast(fmt.tprintf("Copied %s", count_text))
			}
			if len(entries) > 0 && kit.action_button("Clear", "trash", false) {
				console.clear_entries()
			}
		}

		rows := ui.box("rows", {width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 2})

		if ui.scope(rows) {
			for index := len(entries) - 1; index >= 0; index -= 1 {
				build_console_row(index, entries[index])
			}
		}
	}
}

@(private = "file")
build_console_row :: proc(index: int, entry: console.Entry) {
	source_color := kit.colors.youtube if entry.source == "YouTube" else kit.colors.dim
	row := ui.box(fmt.tprintf("entry %d", index), {width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 12, padding = {8, 6, 8, 6}, corner_radius = 6, background = kit.colors.field if index % 2 == 0 else {}})

	if ui.scope(row) {
		ui.box("", {width = ui.points(CONSOLE_TIME_POINTS), height = ui.fit_text(), text_color = kit.colors.faint, font_size = 12}, to_console_time(entry.at))
		ui.box("", {width = ui.points(CONSOLE_SOURCE_POINTS), height = ui.fit_text(), text_color = source_color, font_size = 12, font_weight = .Semibold}, entry.source)
		ui.box("", {width = ui.fill(), height = ui.fit_text(), text_color = kit.colors.text, font_size = 12.5, flags = {.Wrap_Text}}, entry.text)
	}
}

// One line per entry, oldest first, as a log file reads.
@(private = "file")
to_console_text :: proc(entries: []console.Entry) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for entry in entries {
		fmt.sbprintf(&builder, "%s %s: %s\n", to_console_time(entry.at), entry.source, entry.text)
	}

	return strings.to_string(builder)
}

// "18:50:17", in the Mac's own time zone.
@(private = "file")
to_console_time :: proc(at: time.Time) -> string {
	return platform.format_date(f64(time.to_unix_nanoseconds(at)) / 1e6, "HH:mm:ss")
}
