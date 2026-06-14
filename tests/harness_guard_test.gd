extends TestCase

# A normal test with assertions still passes.
func test_normal_assertion_counts() -> void:
	assert_true(true)
	assert_eq(1, 1)
