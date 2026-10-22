package platform

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSDateFormatter")
Date_Formatter :: struct {
	using _: NS.Object,
}

@(objc_class = "NSTimeZone")
Time_Zone :: struct {
	using _: NS.Object,
}

@(objc_class = "NSPasteboard")
Pasteboard :: struct {
	using _: NS.Object,
}

// The text on the clipboard, for Cmd V. It lives until the next frame.
read_clipboard :: proc() -> string {
	board := msg_send(^Pasteboard, Pasteboard, "generalPasteboard")
	text := msg_send(^NS.String, board, "stringForType:", NS.AT("public.utf8-plain-text"))
	if text == nil do return ""

	return strings.clone(text->odinString(), context.temp_allocator)
}

// By template. Only the main thread formats dates.
@(private)
date_formatters: map[string]^Date_Formatter

// A Unix time in ms as local text, by a template such as "d MMM" or "HH:mm", in the order the
// person's locale writes it. It lives until the next frame.
format_date :: proc(unix_ms: f64, template: string) -> string {
	formatter := date_formatters[template] or_else nil

	// A formatter is slow to make, and the Console page formats each of its rows every frame.
	if formatter == nil {
		formatter = msg_send(
			^Date_Formatter,
			msg_send(^Date_Formatter, Date_Formatter, "alloc"),
			"init",
		)
		ns_template := NS.String.alloc()->initWithOdinString(template)
		defer ns_template->release()
		msg_send(nil, formatter, "setLocalizedDateFormatFromTemplate:", ns_template)
		date_formatters[strings.clone(template)] = formatter
	}

	date := msg_send(
		^NS.Object,
		NS.Date,
		"dateWithTimeIntervalSince1970:",
		NS.TimeInterval(unix_ms / 1000),
	)
	text := msg_send(^NS.String, formatter, "stringFromDate:", date)

	return strings.clone(text->odinString(), context.temp_allocator)
}

// How far local time is ahead of UTC, so a date can be compared by local day.
local_offset_seconds :: proc() -> int {
	zone := msg_send(^Time_Zone, Time_Zone, "localTimeZone")

	return int(msg_send(NS.Integer, zone, "secondsFromGMT"))
}

write_clipboard :: proc(text: string) {
	board := msg_send(^Pasteboard, Pasteboard, "generalPasteboard")
	msg_send(NS.Integer, board, "clearContents")

	ns_text := NS.String.alloc()->initWithOdinString(text)
	defer ns_text->release()
	msg_send(NS.BOOL, board, "setString:forType:", ns_text, NS.AT("public.utf8-plain-text"))
}
