package look

import "core:fmt"
import "core:strconv"
import "core:strings"

to_date_text :: proc(date: string) -> string {
	MONTHS :: [12]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}

	parts := strings.split(date, "-", context.temp_allocator)
	if len(parts) < 2 do return date

	month, ok := strconv.parse_int(parts[1])
	if !ok || month < 1 || month > 12 do return date

	months := MONTHS
	if len(parts) < 3 do return fmt.tprintf("%s %s", months[month - 1], parts[0])

	day := strconv.parse_int(parts[2]) or_else 0

	return fmt.tprintf("%d %s %s", day, months[month - 1], parts[0])
}

to_clock_text :: proc(total_seconds: f64) -> string {
	whole_seconds := int(max(0, total_seconds))

	return fmt.tprintf("%d:%02d", whole_seconds / 60, whole_seconds % 60)
}
