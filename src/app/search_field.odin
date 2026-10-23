package app

import "core:encoding/json"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:store"
import "om:ui"

search_field: kit.Text_Field

start_search_field :: proc() {
	kit.register_text_field(&search_field)

	saved, has_term := store.find_state("searchTerm", context.temp_allocator)
	if !has_term do return

	term: string
	if json.unmarshal_string(saved, &term, allocator = context.temp_allocator) != nil do return

	kit.set_field_text(&search_field, term)
}

build_search_field :: proc() {
	if search_field.is_changed {
		bytes, _ := json.marshal(
			kit.to_field_text(&search_field),
			allocator = context.temp_allocator,
		)
		store.save_state("searchTerm", string(bytes))
	}

	if search_field.is_submitted {
		term := strings.trim_space(kit.to_field_text(&search_field))
		if term != "" do core.navigate({kind = .Search, id = strings.clone(term)})
	}

	kit.build_text_field(&search_field, "search", "Search", "magnifyingglass")
	ui.box("", {width = ui.fill(), height = ui.points(6)})
}
