extends TestCase

func test_clone_is_independent_copy() -> void:
	var a := EntityState.new()
	a.pos = Vector3(1, 0, 2)
	a.yaw = 1.5
	var b := a.clone()
	assert_eq(b.pos, Vector3(1, 0, 2))
	assert_almost_eq(b.yaw, 1.5)
	b.pos = Vector3(9, 9, 9)
	assert_eq(a.pos, Vector3(1, 0, 2), "mutating clone must not affect original")
