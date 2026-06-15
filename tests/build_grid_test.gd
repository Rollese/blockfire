extends TestCase

func test_cell_of_floors_to_2m_cells() -> void:
	assert_eq(BuildGrid.cell_of(Vector3(0.5, 0.0, 0.5)), Vector3i(0, 0, 0))
	assert_eq(BuildGrid.cell_of(Vector3(2.1, 0.0, 3.9)), Vector3i(1, 0, 1))
	assert_eq(BuildGrid.cell_of(Vector3(-0.1, 0.0, -2.1)), Vector3i(-1, 0, -2))

func test_world_of_is_cell_centre_xz_base_y() -> void:
	assert_eq(BuildGrid.world_of(Vector3i(0, 0, 0)), Vector3(1.0, 0.0, 1.0))
	assert_eq(BuildGrid.world_of(Vector3i(1, 2, -1)), Vector3(3.0, 4.0, -1.0))

func test_cell_min_is_low_corner() -> void:
	assert_eq(BuildGrid.cell_min(Vector3i(1, 0, -1)), Vector3(2.0, 0.0, -2.0))

func test_in_bounds() -> void:
	assert_eq(BuildGrid.in_bounds(Vector3i(0, 0, 0), 1000.0), true)
	assert_eq(BuildGrid.in_bounds(Vector3i(0, -1, 0), 1000.0), false)   # below ground
	assert_eq(BuildGrid.in_bounds(Vector3i(0, 99, 0), 1000.0), false)   # above stack
	assert_eq(BuildGrid.in_bounds(Vector3i(600, 0, 0), 1000.0), false)  # 600*2m > 1000

func test_yaw_radians() -> void:
	assert_almost_eq(BuildGrid.yaw_radians(0), 0.0)
	assert_almost_eq(BuildGrid.yaw_radians(2), TAU / 4.0)
