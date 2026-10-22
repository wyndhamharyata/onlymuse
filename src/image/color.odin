package image


// to_color reads premultiplied BGRA. It averages the heaviest hue bucket and the two beside it.
// An average of every pixel would mix a purple sky and an orange sun into brown.
// @(private) keeps the procedure inside the image package.
@(private)
to_color :: proc(pixels: []u8) -> Color {
	HUE_BUCKETS :: 36
	sums: [HUE_BUCKETS][3]f32
	weights: [HUE_BUCKETS]f32
	weight_sum: f32
	count: int

	for index := 0; index + 3 < len(pixels); index += 4 {
		alpha := f32(pixels[index + 3]) / 255
		if alpha < 0.5 do continue

		// The division by alpha undoes the premultiplied alpha.
		rgb :=
			[3]f32{f32(pixels[index + 2]), f32(pixels[index + 1]), f32(pixels[index])} /
			(255 * alpha)
		brightest := max(rgb.r, rgb.g, rgb.b)
		spread := brightest - min(rgb.r, rgb.g, rgb.b)
		count += 1
		if spread <= 0 do continue

		saturation := spread / brightest
		// With this weight, a grey wall or a black border counts little against a red coat.
		weight := saturation * saturation * brightest
		bucket := min(int(to_hue(rgb, brightest, spread) * HUE_BUCKETS), HUE_BUCKETS - 1)

		sums[bucket] += rgb * weight
		weights[bucket] += weight
		weight_sum += weight
	}

	if count == 0 || weight_sum <= 0 do return {}

	// Hue goes round, so the bucket before the first is the last.
	best, best_weight := 0, f32(0)
	for bucket in 0 ..< HUE_BUCKETS {
		weight :=
			weights[(bucket + HUE_BUCKETS - 1) % HUE_BUCKETS] +
			weights[bucket] +
			weights[(bucket + 1) % HUE_BUCKETS]
		if weight > best_weight do best, best_weight = bucket, weight
	}

	sum: [3]f32
	for offset in -1 ..= 1 do sum += sums[(best + offset + HUE_BUCKETS) % HUE_BUCKETS]

	return {sum / best_weight, weight_sum / f32(count)}
}

// The hue in turns, from 0 to 1.
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
