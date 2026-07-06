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
