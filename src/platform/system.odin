package platform

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// objc_class binds this struct to the Objective-C class NSDateFormatter.
@(objc_class = "NSDateFormatter")
Date_Formatter :: struct {
	// using embeds NS.Object, so a ^Date_Formatter can stand in for a ^NS.Object.
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
	// objc_send calls the Objective-C method that a selector string names.
	board := objc_send(^Pasteboard, Pasteboard, "generalPasteboard")
	text := objc_send(^NS.String, board, "stringForType:", NS.AT("public.utf8-plain-text"))

	if text == nil do return ""

	// The app frees context.temp_allocator at the start of each frame.
	return strings.clone(text->odinString(), context.temp_allocator)
}

// The formatters, keyed by template. Only the main thread formats dates.
// @(private) keeps this map inside the platform package.
@(private)
date_formatters: map[string]^Date_Formatter

// Formats a Unix time in ms as local text by a template, such as "d MMM" or "HH:mm".
// The person's locale sets the order. The text lives until the next frame.
format_date :: proc(unix_ms: f64, template: string) -> string {
	// or_else gives nil when the map holds no formatter for the template.
	formatter := date_formatters[template] or_else nil

	// A formatter is slow to make. The Console page formats each of its rows every frame.
	if formatter == nil {
		formatter = objc_send(
			^Date_Formatter,
			objc_send(^Date_Formatter, Date_Formatter, "alloc"),
			"init",
		)

		ns_template := NS.String.alloc()->initWithOdinString(template)
		// defer runs release at the end of this if block.
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

// How far local time is ahead of UTC, so the app can compare dates by local day.
local_offset_seconds :: proc() -> int {
	zone := objc_send(^Time_Zone, Time_Zone, "localTimeZone")

	return int(objc_send(NS.Integer, zone, "secondsFromGMT"))
}

write_clipboard :: proc(text: string) {
	board := objc_send(^Pasteboard, Pasteboard, "generalPasteboard")

	objc_send(NS.Integer, board, "clearContents")

	ns_text := NS.String.alloc()->initWithOdinString(text)
	defer ns_text->release()
	objc_send(NS.BOOL, board, "setString:forType:", ns_text, NS.AT("public.utf8-plain-text"))
}
