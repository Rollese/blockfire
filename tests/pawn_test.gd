extends TestCase

func test_moves_along_input_at_speed() -> void:
	var p := Pawn.new(1)
	p.step(1.0, 1.0, 0.0, 0.0)  # 1 second, full +x
	assert_almost_eq(p.pos.x, Pawn.SPEED, 0.001, "travels SPEED metres in 1s")
	assert_almost_eq(p.pos.y, 0.0, 0.001, "stays on ground")

func test_diagonal_input_is_normalized() -> void:
	var p := Pawn.new(1)
	p.step(1.0, 1.0, 1.0, 0.0)
	assert_almost_eq(p.pos.length(), Pawn.SPEED, 0.01, "diagonal not faster than straight")

func test_clamped_to_world_bounds() -> void:
	var p := Pawn.new(1)
	p.pos = Vector3(Pawn.WORLD_HALF - 1.0, 0, 0)
	p.step(1.0, 1.0, 0.0, 0.0)
	assert_almost_eq(p.pos.x, Pawn.WORLD_HALF, 0.001, "cannot exceed world bound")
