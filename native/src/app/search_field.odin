package app

import "core:encoding/json"
import "core:strings"
import "om:store"
import "om:ui"

search_field: Text_Field

start_search_field :: proc() {
	register_text_field(&search_field)

	if saved, ok := store.find_state("searchTerm", context.temp_allocator); ok {
		term: string
		if json.unmarshal_string(saved, &term, allocator = context.temp_allocator) == nil do set_field_text(&search_field, term)
	}
}

// The term is kept for the next run. Return searches.
build_search_field :: proc() {
	if search_field.is_changed {
		bytes, _ := json.marshal(field_text(&search_field), allocator = context.temp_allocator)
		store.save_state("searchTerm", string(bytes))
	}

	if search_field.is_submitted {
		term := strings.trim_space(field_text(&search_field))
		if term != "" do navigate({kind = .Search, id = strings.clone(term)})
	}

	build_text_field(&search_field, "search", "Search", "magnifyingglass")
	ui.box("", {width = ui.fill(), height = ui.points(6)})
}
