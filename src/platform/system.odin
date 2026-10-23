package platform

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

@(private = "file")
PLAIN_TEXT_TYPE :: "public.utf8-plain-text"

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

read_clipboard :: proc() -> string {
	board := objc_send(^Pasteboard, Pasteboard, "generalPasteboard")
	text := objc_send(^NS.String, board, "stringForType:", NS.AT(PLAIN_TEXT_TYPE))

	if text == nil do return ""

	return strings.clone(text->odinString(), context.temp_allocator)
}

@(private)
date_formatters: map[string]^Date_Formatter

format_date :: proc(unix_ms: f64, template: string) -> string {
	formatter := date_formatters[template] or_else nil

	if formatter == nil {
		formatter = objc_send(
			^Date_Formatter,
			objc_send(^Date_Formatter, Date_Formatter, "alloc"),
			"init",
		)

		ns_template := NS.String.alloc()->initWithOdinString(template)
		defer ns_template->release()
		objc_send(nil, formatter, "setLocalizedDateFormatFromTemplate:", ns_template)

		date_formatters[strings.clone(template)] = formatter
	}

	date := objc_send(
		^NS.Object,
		NS.Date,
		"dateWithTimeIntervalSince1970:",
		NS.TimeInterval(unix_ms / 1000),
	)
	text := objc_send(^NS.String, formatter, "stringFromDate:", date)

	return strings.clone(text->odinString(), context.temp_allocator)
}

read_local_offset_seconds :: proc() -> int {
	zone := objc_send(^Time_Zone, Time_Zone, "localTimeZone")

	return int(objc_send(NS.Integer, zone, "secondsFromGMT"))
}

set_clipboard :: proc(text: string) {
	board := objc_send(^Pasteboard, Pasteboard, "generalPasteboard")

	objc_send(NS.Integer, board, "clearContents")

	ns_text := NS.String.alloc()->initWithOdinString(text)
	defer ns_text->release()
	objc_send(NS.BOOL, board, "setString:forType:", ns_text, NS.AT(PLAIN_TEXT_TYPE))
}
