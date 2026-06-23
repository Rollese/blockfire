extends TestCase
## M5.5-P2 suppression pure math (accrue on near-miss, per-tick decay, spread penalty).

func test_accrue_scales_with_closeness() -> void:
	var close := Suppress.accrue(0.0, 0.2)   # 0.2 m away
	var far := Suppress.accrue(0.0, 2.4)     # near the 2.5 m edge
	assert_true(close > far)
	assert_true(close <= 1.0)

func test_accrue_outside_radius_is_noop() -> void:
	assert_almost_eq(Suppress.accrue(0.3, 2.5), 0.3)
	assert_almost_eq(Suppress.accrue(0.3, 9.0), 0.3)

func test_accrue_clamps_at_one() -> void:
	assert_almost_eq(Suppress.accrue(1.0, 0.0), 1.0)

func test_decay_reduces_and_floors_at_zero() -> void:
	assert_almost_eq(Suppress.decay(0.05), 0.01)
	assert_almost_eq(Suppress.decay(0.0), 0.0)
	assert_almost_eq(Suppress.decay(0.02), 0.0)

func test_spread_penalty_zero_below_threshold() -> void:
	assert_almost_eq(Suppress.spread_penalty_deg(0.1), 0.0)
	assert_true(Suppress.spread_penalty_deg(1.0) > 0.0)
	# Monotonic: more suppression never reduces the penalty.
	assert_true(Suppress.spread_penalty_deg(1.0) >= Suppress.spread_penalty_deg(0.5))
