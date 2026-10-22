package youtube

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"

// A Google photo URL ends in its size, as "=w120-h120-l90-rj" or "=s576", which becomes {w} and {h} as in Apple's.
// A video's thumbnail is its plain hqdefault.jpg, which shows it in 16:9 between black bars, cropped away.
@(private)
to_artwork :: proc(reader: ^Reader, url, video_id: string) -> apple.Artwork {
	if strings.contains(url, "i.ytimg.com/vi/") && video_id != "" {
		return {url = fmt.aprintf("https://i.ytimg.com/vi/%s/hqdefault.jpg", video_id, allocator = reader.allocator)}
	}

	if square_start := strings.last_index(url, "=s"); square_start >= 0 && strings.index_any(url[square_start + 2:], "-=") < 0 {
		return {url = fmt.aprintf("%s=w{{w}}-h{{h}}", url[:square_start], allocator = reader.allocator)}
	}

	size_start := strings.last_index(url, "=w")
	if size_start < 0 do return {url = clone(reader, url)}

	rest := url[size_start + 2:]
	dash := strings.index(rest, "-h")
	if dash < 0 do return {url = clone(reader, url)}

	height_end := dash + 2
	for height_end < len(rest) && rest[height_end] >= '0' && rest[height_end] <= '9' do height_end += 1

	return {url = fmt.aprintf("%s=w{{w}}-h{{h}}%s", url[:size_start], rest[height_end:], allocator = reader.allocator)}
}

@(private)
is_wide_thumbnail :: proc(value: json.Value) -> bool {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return false

	last := thumbnails[len(thumbnails) - 1]
	width := as_number(child(last, "width"))
	height := as_number(child(last, "height"))

	return height > 0 && width > height * 1.3
}

// The largest thumbnail's URL, wherever under value its list is.
@(private)
find_thumbnail_url :: proc(value: json.Value) -> string {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return ""

	return as_string(child(thumbnails[len(thumbnails) - 1], "url"))
}

@(private)
find_thumbnails :: proc(value: json.Value) -> json.Array {
	object, ok := value.(json.Object)
	if !ok do return nil

	for key, child_value in object {
		if key == "thumbnails" do return as_array(child_value)
		if found := find_thumbnails(child_value); len(found) > 0 do return found
	}

	return nil
}

@(private)
child :: proc(value: json.Value, keys: ..string) -> json.Value {
	current := value

	for key in keys {
		object, ok := current.(json.Object)
		if !ok do return nil
		current = object[key] or_else nil
	}

	return current
}

@(private)
as_string :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)

	return text
}

@(private)
as_array :: proc(value: json.Value) -> json.Array {
	array, _ := value.(json.Array)

	return array
}

@(private)
as_number :: proc(value: json.Value) -> f64 {
	#partial switch number in value {
	case json.Float:
		return f64(number)
	case json.Integer:
		return f64(number)
	}

	return 0
}

// The text of a "runs" list, joined, or of a "simpleText".
@(private)
to_text :: proc(value: json.Value) -> string {
	if simple := as_string(child(value, "simpleText")); simple != "" do return simple

	builder := strings.builder_make(context.temp_allocator)
	for run in as_array(child(value, "runs")) do strings.write_string(&builder, as_string(child(run, "text")))

	return strings.to_string(builder)
}

@(private)
clone :: proc(reader: ^Reader, text: string) -> string {
	return strings.clone(text, reader.allocator)
}
