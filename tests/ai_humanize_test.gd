extends TestCase
const Humanize := preload("res://bots/ai/humanize.gd")

func test_seeded_rng_is_reproducible() -> void:
	var a := Humanize.new(12345, 0)
	var b := Humanize.new(12345, 0)
	assert_almost_eq(a.aim_jitter(3.0), b.aim_jitter(3.0), 0.0001, "same seed -> same jitter")

func test_different_bot_index_differs() -> void:
	var a := Humanize.new(12345, 0)
	var b := Humanize.new(12345, 7)
	assert_false(is_equal_approx(a.aim_jitter(3.0), b.aim_jitter(3.0)), "per-bot seed differs")

func test_settle_frac_zero_window_is_zero() -> void:
	assert_almost_eq(Humanize.settle_frac(5, 0), 0.0, 0.001, "settle window <= 0 -> 0 (no divide by zero)")

func test_aim_settle_converges_monotonically() -> void:
	var early := Humanize.settle_frac(2, 6)
	var late := Humanize.settle_frac(6, 6)
	assert_true(early > late, "aim error shrinks as the target is tracked")
	assert_almost_eq(late, 0.0, 0.001, "fully settled at the settle window")
