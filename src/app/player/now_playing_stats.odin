package player

import "core:fmt"
import "core:math"
import "core:strings"
import "om:app/core"
import "om:app/kit"
import "om:app/playback"
import "om:helper"
import "om:platform"
import "om:ui"

NARROW_STATS_POINTS :: 720

ONE_STAT_POINTS :: 380

// The plays card is at least this wide to show its bars beside its numbers.
SPARK_BESIDE_POINTS :: 260

STAT_WEEKS :: 8

// The PLAYS, LAST PLAYED, IN LIBRARY SINCE and SKIPS cards of the Now Playing page.
@(private)
build_stats :: proc(song: core.Catalog_Song, info: playback.Song_Info, width: f32) {
	weeks, rank := list_weekly_plays(song)
	last := info.played_date_ms
	added := info.date_added_ms
	skipped := info.skipped_date_ms

	Stat :: struct {
		id, label, value, note: string,
		weight:                 f32,
		weeks:                  [STAT_WEEKS]int,
		has_spark:              bool,
	}

	stats := [4]Stat {
		{
			"plays",
			"PLAYS",
			fmt.tprintf("%d", info.played_count),
			fmt.tprintf("#%d this month", rank) if rank > 0 else "",
			1.4,
			weeks,
			true,
		},
		{
			"last played",
			"LAST PLAYED",
			to_day_text(last) if last > 0 else "Never",
			platform.format_date(last, "HH:mm") if last > 0 else "",
			1,
			{},
			false,
		},
		{
			"added",
			"IN LIBRARY SINCE",
			platform.format_date(added, "d MMM") if added > 0 else "—",
			platform.format_date(added, "yyyy") if added > 0 else "",
			1,
			{},
			false,
		},
		{
			"skips",
			"SKIPS",
			fmt.tprintf("%d", info.skipped_count),
			fmt.tprintf("last on %s", platform.format_date(skipped, "d MMM")) if skipped > 0 else "",
			1,
			{},
			false,
		},
	}

	// On a page narrower than these, four or two cards have no room for their own numbers.
	columns := 4 if width >= NARROW_STATS_POINTS else 2 if width >= ONE_STAT_POINTS else 1

	for start := 0; start < len(stats); start += columns {
		row := ui.box(
			fmt.tprintf("stats %d", start),
			{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = 10},
		)
		in_row := stats[start:min(start + columns, len(stats))]
		row_weight: f32
		for stat in in_row do row_weight += stat.weight

		if ui.scope(row) {
			for stat in in_row {
				// The bars go under the numbers when the numbers have no room beside them.
				card_width := (width - 10 * f32(len(in_row) - 1)) * stat.weight / row_weight
				is_stacked := stat.has_spark && card_width < SPARK_BESIDE_POINTS
				card := build_stat_card(
					stat.id,
					stat.label,
					stat.value,
					stat.note,
					stat.weight,
					is_stacked,
				)

				if stat.has_spark {
					if ui.scope(card) do build_spark(stat.weeks)
				}
			}
		}
	}
}

@(private = "file")
build_stat_card :: proc(
	id, label, value, note_text: string,
	weight: f32 = 1,
	is_stacked := false,
) -> ^ui.Box {
	card := ui.box(
		id,
		{
			width = ui.fill(weight),
			height = ui.fit_children(),
			axis = .Y if is_stacked else .X,
			align = .Start if is_stacked else .End,
			gap = 8 if is_stacked else 0,
			padding = {14, 12, 14, 12},
			corner_radius = 10,
			background = kit.to_color(0xffffff0a),
			border_width = 1,
			border_color = kit.to_color(0xffffff10),
		},
	)

	if ui.scope(card) {
		column := ui.box(
			"text",
			{width = ui.fill(), height = ui.fit_children(), axis = .Y, gap = 1},
		)

		if ui.scope(column) {
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.faint,
					font_size = 11,
					font_weight = .Semibold,
				},
				label,
			)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.text,
					font_size = 24,
					font_weight = .Bold,
					flags = {.Truncate_Text},
				},
				value,
			)
			ui.box(
				"",
				{
					width = ui.fill(),
					height = ui.fit_text(),
					text_color = kit.colors.dim,
					font_size = 12,
					flags = {.Truncate_Text},
				},
				note_text,
			)
		}
	}

	return card
}

// The song's plays in each of the last STAT_WEEKS weeks, oldest first, from the app's own log.
// Its rank among the songs played in the last 30 days, or 0 when it has no play there.
@(private = "file")
weekly_plays: struct {
	// The page asks each frame. The counts hold until the song, the log length or the hour changes.
	song_id:   string,
	log_count: int,
	hour:      i64,
	weeks:     [STAT_WEEKS]int,
	rank:      int,
}

@(private = "file")
list_weekly_plays :: proc(song: core.Catalog_Song) -> (weeks: [STAT_WEEKS]int, rank: int) {
	now_ms := i64(helper.now_ms())
	hour := now_ms / 3_600_000
	is_counted :=
		weekly_plays.song_id == song.id &&
		weekly_plays.log_count == len(playback.play_log) &&
		weekly_plays.hour == hour
	if is_counted do return weekly_plays.weeks, weekly_plays.rank

	weeks, rank = list_weekly_plays_from_log(song, now_ms)
	delete(weekly_plays.song_id)
	weekly_plays = {strings.clone(song.id), len(playback.play_log), hour, weeks, rank}

	return weeks, rank
}

@(private = "file")
list_weekly_plays_from_log :: proc(
	song: core.Catalog_Song,
	now_ms: i64,
) -> (
	weeks: [STAT_WEEKS]int,
	rank: int,
) {
	week_ms: i64 = 7 * 86_400_000
	month_start_ms := now_ms - 30 * 86_400_000
	counts := make(map[string]int, context.temp_allocator)
	own := 0

	for play in playback.play_log {
		if play.is_skip do continue

		if playback.is_same_song(play, song) {
			age := int((now_ms - play.played_at_ms) / week_ms)
			// A play dated ahead of now, after the Mac's clock moved back, has a negative age.
			if age >= 0 && age < STAT_WEEKS do weeks[STAT_WEEKS - 1 - age] += 1
		}

		if play.played_at_ms >= month_start_ms {
			// \x1f, the ASCII unit separator, never shows in a name, so it keeps the two apart.
			key := fmt.tprintf("%s\x1f%s", play.name, play.artist)
			counts[key] += 1
			if playback.is_same_song(play, song) do own = counts[key]
		}
	}

	if own == 0 do return weeks, 0

	rank = 1
	for _, count in counts do if count > own do rank += 1

	return weeks, rank
}

// The bars of the PLAYS card, one for each week, oldest first.
@(private = "file")
build_spark :: proc(weeks: [STAT_WEEKS]int) {
	most := 1
	for count in weeks do most = max(most, count)

	spark := ui.box(
		"spark",
		{width = ui.points(120), height = ui.points(30), axis = .X, align = .End, gap = 3},
	)

	if ui.scope(spark) {
		for count, index in weeks {
			height := max(3, 30 * f32(count) / f32(most))

			ui.box(
				fmt.tprintf("week %d", index),
				{
					width = ui.fill(),
					height = ui.points(height),
					corner_radius = 2,
					background = {
						core.app.accent.r,
						core.app.accent.g,
						core.app.accent.b,
						0.75 if count > 0 else 0.2,
					},
				},
			)
		}
	}
}

// "Today", "Yesterday" or "3 Oct", by local day.
@(private = "file")
to_day_text :: proc(unix_ms: f64) -> string {
	zone_seconds := f64(platform.local_offset_seconds())
	to_day :: proc(time_ms, offset_seconds: f64) -> int {
		return int(math.floor((time_ms / 1000 + offset_seconds) / 86_400))
	}
	days := to_day(helper.now_ms(), zone_seconds) - to_day(unix_ms, zone_seconds)

	switch days {
	case 0:
		return "Today"
	case 1:
		return "Yesterday"
	}

	return platform.format_date(unix_ms, "d MMM")
}
