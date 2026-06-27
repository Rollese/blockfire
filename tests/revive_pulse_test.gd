extends TestCase
## RevivePulse (M7): vertical bob for the downed-teammate revive marker, so a friendly who needs a
## revive draws the eye instead of reading like a normal (alive) friendly marker. Pure + time-based.

func test_starts_at_rest() -> void:
	assert_almost_eq(RevivePulse.bob(0.0), 0.0, 0.001, "the bob begins at zero (no jump on spawn)")

func test_bounded_to_amplitude() -> void:
	for i in range(120):
		var t := float(i) * 0.05
		var b := RevivePulse.bob(t)
		assert_true(b >= -0.001 and b <= RevivePulse.AMP + 0.001, "bob stays within [0, AMP]")

func test_reaches_near_peak_at_half_period() -> void:
	# (1-cos)/2 peaks at half a period.
	var half := 0.5 / RevivePulse.HZ
	assert_almost_eq(RevivePulse.bob(half), RevivePulse.AMP, 0.01, "peaks ~AMP at the half period")

func test_is_periodic() -> void:
	var period := 1.0 / RevivePulse.HZ
	assert_almost_eq(RevivePulse.bob(0.3), RevivePulse.bob(0.3 + period), 0.01, "one full period repeats")
