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

MIN_FOUR_COLUMNS_POINTS :: 720

MIN_TWO_COLUMNS_POINTS :: 380

MIN_BARS_BESIDE_POINTS :: 260

STAT_GAP_POINTS :: 10

BARS_HEIGHT_POINTS :: 30

STAT_WEEKS :: 8

RANK_DAYS :: 30

@(private)
build_stats :: proc(song: core.Catalog_Song, info: playback.Song_Info, width: f32) {
	weeks, rank := list_weekly_plays(song)
	last_ms := info.played_date_ms
	added_ms := info.date_added_ms
	skipped_ms := info.skipped_date_ms
	now_ms := helper.now_ms()
	zone_seconds := f64(platform.read_local_offset_seconds())

	Stat :: struct {
		id, label, value, note: string,
		weight:                 f32,
		weeks:                  [STAT_WEEKS]int,
		has_bars:               bool,
	}

	stats := [4]Stat {
		{
			"plays",
			"PLAYS",
			fmt.tprintf("%d", info.played_count),
			fmt.tprintf("#%d in the last %d days", rank, RANK_DAYS) if rank > 0 else "",
			1.4,
			weeks,
			true,
		},
		{
			"last played",
			"LAST PLAYED",
			to_day_text(last_ms, now_ms, zone_seconds) if last_ms > 0 else "Never",
			platform.format_date(last_ms, "HH:mm") if last_ms > 0 else "",
			1,
			{},
			false,
		},
		{
			"added",
			"IN LIBRARY SINCE",
			platform.format_date(added_ms, "d MMM") if added_ms > 0 else "Unknown",
			platform.format_date(added_ms, "yyyy") if added_ms > 0 else "",
			1,
			{},
			false,
		},
		{
			"skips",
			"SKIPS",
			fmt.tprintf("%d", info.skipped_count),
			fmt.tprintf("last on %s", platform.format_date(skipped_ms, "d MMM")) if skipped_ms > 0 else "",
			1,
			{},
			false,
		},
	}

	columns := 1

	if width >= MIN_FOUR_COLUMNS_POINTS {
		columns = 4
	} else if width >= MIN_TWO_COLUMNS_POINTS {
		columns = 2
	}

	for start := 0; start < len(stats); start += columns {
		row := ui.box(
			fmt.tprintf("stats %d", start),
			{width = ui.fill(), height = ui.fit_children(), axis = .X, gap = STAT_GAP_POINTS},
		)
		in_row := stats[start:min(start + columns, len(stats))]
		row_weight: f32
		for stat in in_row do row_weight += stat.weight

		if ui.scope(row) {
			for stat in in_row {
				gaps_width := STAT_GAP_POINTS * f32(len(in_row) - 1)
				card_width := (width - gaps_width) * stat.weight / row_weight
				is_stacked := stat.has_bars && card_width < MIN_BARS_BESIDE_POINTS
				card := build_stat_card(
					stat.id,
					stat.label,
					stat.value,
					stat.note,
					stat.weight,
					is_stacked,
				)

				if stat.has_bars {
					if ui.scope(card) do build_bars(stat.weeks)
				}
			}
		}
	}
}

@(private = "file")
build_stat_card :: proc(
	id, label, value, note_text: string,
	weight: f32,
	is_stacked: bool,
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
			background = kit.colors.detail_card,
			border_width = 1,
			border_color = kit.colors.detail_card_border,
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

@(private = "file")
weekly_plays: struct {
	song_id:   string,
	log_count: int,
	hour:      i64,
	weeks:     [STAT_WEEKS]int,
	rank:      int,
}

@(private = "file")
list_weekly_plays :: proc(song: core.Catalog_Song) -> (weeks: [STAT_WEEKS]int, rank: int) {
	now_ms := i64(helper.now_ms())
	hour := now_ms / core.HOUR_MS
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
	week_ms: i64 = 7 * core.DAY_MS
	rank_start_ms := now_ms - RANK_DAYS * core.DAY_MS
	counts := make(map[string]int, context.temp_allocator)
	own_count := 0

	for play in playback.play_log {
		if play.is_skip do continue

		is_own := playback.is_same_song(play, song)
		age := int((now_ms - play.played_at_ms) / week_ms)
		// A play dated ahead of now, after the Mac's clock moved back, has a negative age.
		is_in_range := age >= 0 && age < STAT_WEEKS
		if is_own && is_in_range do weeks[STAT_WEEKS - 1 - age] += 1

		if play.played_at_ms >= rank_start_ms {
			key := fmt.tprintf("%s\x1f%s", play.name, play.artist)
			counts[key] += 1
			if is_own do own_count = counts[key]
		}
	}

	if own_count == 0 do return weeks, 0

	rank = 1
	for _, count in counts do if count > own_count do rank += 1

	return weeks, rank
}

@(private = "file")
build_bars :: proc(weeks: [STAT_WEEKS]int) {
	max_count := 1
	for count in weeks do max_count = max(max_count, count)

	bars := ui.box(
		"bars",
		{
			width = ui.points(120),
			height = ui.points(BARS_HEIGHT_POINTS),
			axis = .X,
			align = .End,
			gap = 3,
		},
	)

	if ui.scope(bars) {
		for count, index in weeks {
			height := max(3, BARS_HEIGHT_POINTS * f32(count) / f32(max_count))

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

@(private = "file")
to_day :: proc(time_ms, zone_seconds: f64) -> int {
	return int(math.floor((time_ms / 1000 + zone_seconds) / core.DAY_SECONDS))
}

@(private = "file")
to_day_text :: proc(unix_ms, now_ms, zone_seconds: f64) -> string {
	days := to_day(now_ms, zone_seconds) - to_day(unix_ms, zone_seconds)

	switch days {
	case 0:
		return "Today"
	case 1:
		return "Yesterday"
	}

	return platform.format_date(unix_ms, "d MMM")
}
