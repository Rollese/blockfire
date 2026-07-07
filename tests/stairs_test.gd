extends TestCase
const Stairs := preload("res://shared/sim/stairs.gd")

func test_run_dir_quarter_turns() -> void:
	assert_eq(Stairs.run_dir(0), Vector2(0, 1), "yaw 0 ascends +Z")
	assert_eq(Stairs.run_dir(2), Vector2(1, 0), "yaw 2 ascends +X")
	assert_eq(Stairs.run_dir(4), Vector2(0, -1), "yaw 4 ascends -Z")
	assert_eq(Stairs.run_dir(6), Vector2(-1, 0), "yaw 6 ascends -X")

func test_surface_rises_low_to_high_edge() -> void:
	# Cell y=1 -> base 2.4 m, next floor 4.8 m; z runs 0..CELL(2.4) across the cell.
	var cell := Vector3i(0, 1, 0)
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 0.0), 2.4, 0.01, "low edge = cell base")
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 2.4), 4.8, 0.01, "high edge = next floor")
	assert_almost_eq(Stairs.surface_at(cell, 0, 1.0, 1.2), 3.6, 0.01, "mid = halfway up")

func test_surface_respects_yaw_direction() -> void:
	var cell := Vector3i(0, 1, 0)
	assert_almost_eq(Stairs.surface_at(cell, 4, 1.0, 0.0), 4.8, 0.01, "yaw4 low-z edge is the top")
	assert_almost_eq(Stairs.surface_at(cell, 4, 1.0, 2.4), 2.4, 0.01, "yaw4 high-z edge is the bottom")
