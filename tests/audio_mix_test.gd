extends TestCase

func test_distance_gain_flat_inside_unit_size() -> void:
	assert_almost_eq(AudioMix.distance_gain(0.0, 8.0, 400.0), 1.0, 0.0001, "at source = full")
	assert_almost_eq(AudioMix.distance_gain(8.0, 8.0, 400.0), 1.0, 0.0001, "at unit_size = full")

func test_distance_gain_zero_at_or_past_max() -> void:
	assert_eq(AudioMix.distance_gain(400.0, 8.0, 400.0), 0.0, "at max_distance = silent (culled)")
	assert_eq(AudioMix.distance_gain(999.0, 8.0, 400.0), 0.0, "past max = silent")

func test_distance_gain_inverse_and_monotonic() -> void:
	var g16 := AudioMix.distance_gain(16.0, 8.0, 400.0)
	var g32 := AudioMix.distance_gain(32.0, 8.0, 400.0)
	assert_almost_eq(g16, 0.5, 0.0001, "unit_size/d = 8/16")
	assert_true(g32 < g16, "monotonic non-increasing with distance")

func test_occlusion_gain_drops_but_never_silent() -> void:
	assert_almost_eq(AudioMix.occlusion_gain(0.0), 1.0, 0.0001, "clear LOS = full")
	assert_true(AudioMix.occlusion_gain(1.0) >= AudioMix.OCCLUSION_MIN_GAIN - 0.0001, "fully blocked still audible")
	assert_true(AudioMix.occlusion_gain(1.0) < AudioMix.occlusion_gain(0.0), "blocked quieter than clear")

func test_occlusion_cutoff_darkens_with_coverage() -> void:
	assert_almost_eq(AudioMix.occlusion_cutoff(0.0), AudioMix.OPEN_CUTOFF_HZ, 1.0, "clear = open")
	assert_true(AudioMix.occlusion_cutoff(1.0) < AudioMix.occlusion_cutoff(0.0), "blocked = darker")

func test_suppression_noop_below_threshold() -> void:
	assert_almost_eq(AudioMix.suppression_cutoff(0.0), AudioMix.OPEN_CUTOFF_HZ, 1.0, "no suppression = open")
	assert_almost_eq(AudioMix.suppression_duck(0.0), 1.0, 0.0001, "no suppression = no duck")
	assert_almost_eq(AudioMix.suppression_cutoff(0.1), AudioMix.OPEN_CUTOFF_HZ, 1.0, "below threshold = open")

func test_suppression_darkens_and_ducks_above_threshold() -> void:
	assert_true(AudioMix.suppression_cutoff(1.0) < AudioMix.OPEN_CUTOFF_HZ, "full suppression darkens")
	assert_true(AudioMix.suppression_duck(1.0) < 1.0, "full suppression ducks")

func test_bang_delay_grows_and_collapses_close() -> void:
	assert_eq(AudioMix.bang_delay_ticks(10.0), 0, "close range = no crack/bang split")
	assert_true(AudioMix.bang_delay_ticks(343.0) > AudioMix.bang_delay_ticks(100.0), "farther = longer delay")

func test_combine_multiplies_gain_takes_min_cutoff() -> void:
	var out := AudioMix.combine(0.5, 1.0, 5000.0)
	assert_almost_eq(out["gain"], 0.5 * AudioMix.OCCLUSION_MIN_GAIN, 0.0001, "dist*occ gain")
	assert_true(out["cutoff"] <= 5000.0, "cutoff is the min of occlusion and def cutoff")
