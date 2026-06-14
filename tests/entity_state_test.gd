extends TestCase

func test_clone_copies_all_fields() -> void:
	var a := EntityState.new()
	a.pos = Vector3(1, 2, 3); a.yaw = 0.5; a.pitch = -0.2
	a.stance = 1; a.lean = 2; a.team = 1; a.alive = false; a.health = 42
	var b := a.clone()
	assert_eq(b.pos, Vector3(1, 2, 3))
	assert_almost_eq(b.pitch, -0.2)
	assert_eq(b.stance, 1); assert_eq(b.lean, 2); assert_eq(b.team, 1)
	assert_eq(b.alive, false); assert_eq(b.health, 42)
	b.health = 99
	assert_eq(a.health, 42, "clone independent")
