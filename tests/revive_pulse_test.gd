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

# --- bleed-out urgency (DOWNED_LIST) ---

func test_hz_ramps_faster_near_death() -> void:
	assert_almost_eq(RevivePulse.hz_for(1.0), RevivePulse.HZ, 0.01, "just-downed bobs at the calm rate")
	assert_almost_eq(RevivePulse.hz_for(0.0), RevivePulse.HZ_URGENT, 0.01, "near death bobs at the urgent rate")
	assert_true(RevivePulse.hz_for(0.2) > RevivePulse.hz_for(0.8), "lower bleed fraction => faster bob")

func test_halted_holds_calm_rate() -> void:
	assert_almost_eq(RevivePulse.hz_for(0.0, true), RevivePulse.HZ, 0.01, "a self-bandaged pawn is stabilised — calm bob even at frac 0")

func test_urgency_bob_bigger_near_death() -> void:
	# Sample the peak of each (half its own period) — near-death travel exceeds calm travel.
	var calm_peak := RevivePulse.urgency_bob(0.5 / RevivePulse.hz_for(1.0), 1.0)
	var urgent_peak := RevivePulse.urgency_bob(0.5 / RevivePulse.hz_for(0.0), 0.0)
	assert_true(urgent_peak > calm_peak, "near-death marker bobs higher than a just-downed one")

func test_urgency_bob_starts_at_rest() -> void:
	assert_almost_eq(RevivePulse.urgency_bob(0.0, 0.5), 0.0, 0.001, "urgency bob also begins at zero")
