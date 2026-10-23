package youtube

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "om:apple"

@(private)
MIN_WIDE_ASPECT :: 1.3

// A Google photo URL ends in its size, as "=w120-h120-l90-rj" or "=s576".
@(private)
to_artwork :: proc(reader: ^Reader, url, video_id: string) -> apple.Artwork {
	// A video's thumbnail is hqdefault.jpg. It shows 16:9 between black bars, which the app crops.
	is_video_thumbnail := strings.contains(url, "i.ytimg.com/vi/") && video_id != ""

	if is_video_thumbnail {
		return {
			url = fmt.aprintf(
				"https://i.ytimg.com/vi/%s/hqdefault.jpg",
				video_id,
				allocator = reader.allocator,
			),
		}
	}

	if square_start := strings.last_index(url, "=s");
	   square_start >= 0 && strings.index_any(url[square_start + len("=s"):], "-=") < 0 {
		return {
			url = fmt.aprintf(
				"%s=w{{w}}-h{{h}}",
				url[:square_start],
				allocator = reader.allocator,
			),
		}
	}

	size_start := strings.last_index(url, "=w")
	if size_start < 0 do return {url = make_copy(reader, url)}

	rest := url[size_start + len("=w"):]
	dash := strings.index(rest, "-h")
	if dash < 0 do return {url = make_copy(reader, url)}

	height_end := dash + len("-h")

	for height_end < len(rest) && rest[height_end] >= '0' && rest[height_end] <= '9' {
		height_end += 1
	}

	return {
		url = fmt.aprintf(
			"%s=w{{w}}-h{{h}}%s",
			url[:size_start],
			rest[height_end:],
			allocator = reader.allocator,
		),
	}
}

@(private)
is_wide_thumbnail :: proc(value: json.Value) -> bool {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return false

	last := thumbnails[len(thumbnails) - 1]
	width := to_number(find_child(last, "width"))
	height := to_number(find_child(last, "height"))

	return height > 0 && width > height * MIN_WIDE_ASPECT
}

@(private)
find_thumbnail_url :: proc(value: json.Value) -> string {
	thumbnails := find_thumbnails(value)
	if len(thumbnails) == 0 do return ""

	return to_string(find_child(thumbnails[len(thumbnails) - 1], "url"))
}

@(private)
find_thumbnails :: proc(value: json.Value) -> json.Array {
	object, ok := value.(json.Object)
	if !ok do return nil

	for key, child_value in object {
		if key == "thumbnails" do return to_array(child_value)
		if found := find_thumbnails(child_value); len(found) > 0 do return found
	}

	return nil
}

@(private)
find_child :: proc(value: json.Value, keys: ..string) -> json.Value {
	current := value

	for key in keys {
		object, ok := current.(json.Object)
		if !ok do return nil
		current = object[key] or_else nil
	}

	return current
}

@(private)
to_string :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)

	return text
}

@(private)
to_array :: proc(value: json.Value) -> json.Array {
	array, _ := value.(json.Array)

	return array
}

@(private)
to_number :: proc(value: json.Value) -> f64 {
	#partial switch number in value {
	case json.Float:
		return f64(number)
	case json.Integer:
		return f64(number)
	}

	return 0
}

@(private)
to_text :: proc(value: json.Value) -> string {
	if simple := to_string(find_child(value, "simpleText")); simple != "" do return simple

	builder := strings.builder_make(context.temp_allocator)

	for run in to_array(find_child(value, "runs")) {
		strings.write_string(&builder, to_string(find_child(run, "text")))
	}

	return strings.to_string(builder)
}

@(private)
make_copy :: proc(reader: ^Reader, text: string) -> string {
	return strings.clone(text, reader.allocator)
}
