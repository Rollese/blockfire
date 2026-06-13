extends TestCase

func test_query_returns_only_within_radius() -> void:
	var grid := InterestGrid.new(64.0)
	var positions := {
		1: Vector3(0, 0, 0),
		2: Vector3(50, 0, 0),     # within 100
		3: Vector3(300, 0, 0),    # outside 100
	}
	for id in positions:
		grid.insert(id, positions[id])
	var ids := grid.query(Vector3.ZERO, 100.0, positions)
	ids.sort()
	assert_eq(ids, [1, 2])

func test_clear_empties_grid() -> void:
	var grid := InterestGrid.new(64.0)
	grid.insert(1, Vector3.ZERO)
	grid.clear()
	var positions := {1: Vector3.ZERO}
	assert_eq(grid.query(Vector3.ZERO, 100.0, positions), [])
