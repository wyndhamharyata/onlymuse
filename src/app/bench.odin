package app

import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import "om:app/core"
import "om:app/kit"
import "om:image"
import "om:platform"
import "om:ui"

// The first frames open the window and load fonts, so the bench leaves them out.
BENCH_SKIPPED_FRAME_COUNT :: 10

build_frame_time :: proc() {
	count := len(core.app.build_durations)
	if count == 0 || !core.app.is_showing_frames do return

	last := time.duration_milliseconds(core.app.build_durations[count - 1])
	root := ui.current_parent()

	ui.box(
		"",
		{
			width = ui.points(110),
			height = ui.points(20),
			position = {root.style.width.value - 120, 8},
			text_align = .End,
			text_color = kit.colors.faint,
			font_size = 11,
			flags = {.Floating},
		},
		fmt.tprintf("frame %.2f ms", last),
	)
}

finish_bench :: proc() {
	remove_range(&core.app.build_durations, 0, BENCH_SKIPPED_FRAME_COUNT)
	remove_range(&core.app.frame_starts, 0, BENCH_SKIPPED_FRAME_COUNT)

	builds := core.app.build_durations[:]
	slice.sort(builds)

	gaps: [dynamic]time.Duration

	for index in 1 ..< len(core.app.frame_starts) {
		append(
			&gaps,
			time.tick_diff(core.app.frame_starts[index - 1], core.app.frame_starts[index]),
		)
	}

	slice.sort(gaps[:])

	to_ms :: proc(values: []time.Duration, fraction: f64) -> f64 {
		return time.duration_milliseconds(values[int(math.floor(f64(len(values) - 1) * fraction))])
	}

	fmt.printfln(
		"build per frame ms: p50 %.2f p99 %.2f max %.2f",
		to_ms(builds, 0.5),
		to_ms(builds, 0.99),
		to_ms(builds, 1),
	)

	ready, total := image.count()
	fmt.printfln("covers on the GPU %d, known %d", ready, total)

	fmt.printfln(
		"gap between frames ms: p50 %.2f p99 %.2f max %.2f",
		to_ms(gaps[:], 0.5),
		to_ms(gaps[:], 0.99),
		to_ms(gaps[:], 1),
	)

	platform.quit()
}
