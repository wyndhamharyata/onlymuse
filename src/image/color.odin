package image

@(private)
to_color :: proc(pixels: []u8) -> Color {
	HUE_BUCKET_COUNT :: 36
	sums: [HUE_BUCKET_COUNT][3]f32
	weights: [HUE_BUCKET_COUNT]f32
	weight_sum: f32
	opaque_count: int

	for index := 0; index + 3 < len(pixels); index += BYTES_PER_PIXEL {
		alpha := f32(pixels[index + 3]) / 255
		if alpha < 0.5 do continue

		rgb :=
			[3]f32{f32(pixels[index + 2]), f32(pixels[index + 1]), f32(pixels[index])} /
			(255 * alpha)
		brightest := max(rgb.r, rgb.g, rgb.b)
		spread := brightest - min(rgb.r, rgb.g, rgb.b)
		opaque_count += 1
		if spread <= 0 do continue

		saturation := spread / brightest
		weight := saturation * saturation * brightest
		bucket := min(int(to_hue(rgb, brightest, spread) * HUE_BUCKET_COUNT), HUE_BUCKET_COUNT - 1)

		sums[bucket] += rgb * weight
		weights[bucket] += weight
		weight_sum += weight
	}

	if weight_sum <= 0 do return {}

	best_bucket, best_weight := 0, f32(0)

	for bucket in 0 ..< HUE_BUCKET_COUNT {
		weight: f32

		for offset in -1 ..= 1 {
			weight += weights[(bucket + offset + HUE_BUCKET_COUNT) % HUE_BUCKET_COUNT]
		}

		if weight > best_weight do best_bucket, best_weight = bucket, weight
	}

	sum: [3]f32

	for offset in -1 ..= 1 {
		sum += sums[(best_bucket + offset + HUE_BUCKET_COUNT) % HUE_BUCKET_COUNT]
	}

	return {sum / best_weight, weight_sum / f32(opaque_count)}
}

@(private)
to_hue :: proc(rgb: [3]f32, brightest, spread: f32) -> f32 {
	hue: f32

	switch brightest {
	case rgb.r:
		hue = (rgb.g - rgb.b) / spread
	case rgb.g:
		hue = (rgb.b - rgb.r) / spread + 2
	case:
		hue = (rgb.r - rgb.g) / spread + 4
	}

	hue /= 6

	return hue + 1 if hue < 0 else hue
}
