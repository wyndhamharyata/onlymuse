package look

import "core:fmt"
import "core:strconv"
import "core:strings"
import "thor:platform"

// A date from Apple, as "2024-05-17" or "2024-05", written as the person's language writes dates.
to_date_text :: proc(text: string) -> string {
	parts := strings.split(text, "-", context.temp_allocator)
	if len(parts) < 2 do return text

	year, has_year := strconv.parse_int(parts[0])
	month, has_month := strconv.parse_int(parts[1])
	if !has_year || !has_month || month < 1 || month > 12 do return text

	if len(parts) < 3 do return platform.format_date({i64(year), i8(month), 1}, "yMMM")

	day, has_day := strconv.parse_int(parts[2])
	if !has_day || day < 1 || day > 31 do return text

	return platform.format_date({i64(year), i8(month), i8(day)}, "yMMMd")
}

to_clock_text :: proc(total_seconds: f64) -> string {
	whole_seconds := int(max(0, total_seconds))

	return fmt.tprintf("%d:%02d", whole_seconds / 60, whole_seconds % 60)
}
