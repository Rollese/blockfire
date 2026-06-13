extends TestCase

func test_harness_runs_and_asserts() -> void:
	assert_true(true, "trivial")
	assert_eq(1 + 1, 2)
	assert_almost_eq(0.1 + 0.2, 0.3)
