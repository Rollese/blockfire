extends TestCase
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# A 3x3 grid, spacing 2 m, origin (-2,-2) -> covers world [-2..2] on both axes.
# Heights (row-major, z outer / x inner):
#   z=-2: 0 0 0
#   z= 0: 0 4 0
#   z= 2: 0 0 0
func _grid() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 3; g.rows = 3; g.spacing = 2.0
	g.origin_x = -2.0; g.origin_z = -2.0
	g.samples = PackedFloat32Array([0,0,0, 0,4,0, 0,0,0])
	return g

# A uniformly steep ramp rising 4 m per 2 m cell in +x -> gradient 2.0/m -> atan(2)=63.4 deg (> MAX).
func _steep_ramp() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 11; g.rows = 11; g.spacing = 2.0; g.origin_x = -10.0; g.origin_z = -10.0
	var s := PackedFloat32Array(); s.resize(121)
	for zi in 11:
		for xi in 11:
			s[zi*11 + xi] = float(xi) * 4.0
	g.samples = s
	return g

func test_null_grid_is_flat() -> void:
	assert_eq(Terrain.height_at(null, 0.0, 0.0), 0.0, "null grid = flat")
	assert_eq(Terrain.height_at(null, 123.0, -77.0), 0.0, "null grid flat anywhere")

func test_height_at_grid_points() -> void:
	assert_almost_eq(Terrain.height_at(_grid(), 0.0, 0.0), 4.0, 0.001, "peak sample")
	assert_almost_eq(Terrain.height_at(_grid(), -2.0, -2.0), 0.0, 0.001, "corner sample")
	assert_almost_eq(Terrain.height_at(_grid(), 2.0, 2.0), 0.0, 0.001, "far corner")

func test_height_at_midpoints_bilinear() -> void:
	assert_almost_eq(Terrain.height_at(_grid(), 1.0, 0.0), 2.0, 0.001, "x-midpoint")
	assert_almost_eq(Terrain.height_at(_grid(), 0.0, 1.0), 2.0, 0.001, "z-midpoint")
	assert_almost_eq(Terrain.height_at(_grid(), 1.0, 1.0), 1.0, 0.001, "diagonal midpoint")

func test_height_at_clamps_out_of_bounds() -> void:
	assert_almost_eq(Terrain.height_at(_grid(), -50.0, -50.0), 0.0, 0.001, "clamp to nearest edge, no crash")
	assert_almost_eq(Terrain.height_at(_grid(), 50.0, 0.0), 0.0, 0.001, "clamp +x edge")

func test_cutout_suppresses_terrain() -> void:
	var g := _grid()
	g.cutouts = [{"min_x": -0.5, "max_x": 0.5, "min_z": -0.5, "max_z": 0.5, "floor_y": -100.0}]
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), -100.0, 0.001, "inside cutout: terrain suppressed to low floor")
	assert_almost_eq(Terrain.height_at(g, 2.0, 0.0), 0.0, 0.001, "outside cutout: normal terrain")

func test_slope_flat_is_zero() -> void:
	assert_almost_eq(Terrain.slope_at(null, 0.0, 0.0), 0.0, 0.001, "null = flat, 0 deg")
	assert_almost_eq(Terrain.slope_at(_grid(), -2.0, -2.0), 0.0, 0.001, "flat corner ~0 deg")

func test_slope_on_incline_is_positive() -> void:
	# central difference on a linear ramp yields the true gradient: 4 m / 2 m cell = 2.0/m -> atan(2)=63.4 deg
	var s := Terrain.slope_at(_steep_ramp(), 0.0, 0.0)
	assert_true(s > 50.0, "steep ramp reads steep (got %f)" % s)

func test_resolve_movement_null_grid_passes() -> void:
	var to := Vector3(5, 0, 5)
	assert_eq(Terrain.resolve_movement(null, Vector3(0,0,0), to), to, "null grid never blocks")

func test_resolve_movement_gentle_slope_passes() -> void:
	var g := TerrainGrid.new()
	g.cols = 11; g.rows = 11; g.spacing = 2.0; g.origin_x = -10.0; g.origin_z = -10.0
	var s := PackedFloat32Array()
	s.resize(121)
	for zi in 11:
		for xi in 11:
			s[zi*11 + xi] = float(xi) * 0.2   # 0.1 m per m of x -> ~5.7 deg
	g.samples = s
	var to := Vector3(2, 0, 0)
	assert_eq(Terrain.resolve_movement(g, Vector3(0,0,0), to), to, "gentle slope walkable")

func test_resolve_movement_too_steep_is_clipped() -> void:
	var g := _steep_ramp()
	var from := Vector3(-4, 0, 0)
	var to := Vector3(0, 0, 0)   # up the steep ramp, slope > MAX_WALKABLE_SLOPE_DEG
	var out := Terrain.resolve_movement(g, from, to)
	assert_ne(out, to, "too-steep destination is not reached (clipped/slid)")
