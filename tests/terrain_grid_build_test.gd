extends TestCase
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# Build a 5x5 image (world_half=4, spacing=2 -> 5 samples per axis) with a linear x-ramp:
# red 0.0 at x-col 0 .. 1.0 at x-col 4.
func _ramp_img() -> Image:
	var img := Image.create(5, 5, false, Image.FORMAT_RGBF)
	for zi in 5:
		for xi in 5:
			var v := float(xi) / 4.0
			img.set_pixel(xi, zi, Color(v, v, v))
	return img

func test_build_grid_maps_brightness_to_height() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	assert_eq(g.cols, 5, "cols")
	assert_eq(g.rows, 5, "rows")
	assert_almost_eq(g.origin_x, -4.0, 0.001, "origin = -world_half")
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), 0.0, 0.01, "min brightness -> height_min")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 10.0, 0.01, "max brightness -> height_min+scale")
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), 5.0, 0.01, "mid brightness -> mid height")

func test_build_grid_height_min_offset() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, -3.0, 6.0)
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), -3.0, 0.01, "height_min applied")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 3.0, 0.01, "height_min + scale")

func test_flatten_pad_levels_a_footprint() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	Terrain.flatten_pad(g, -4.0, 4.0, -4.0, 4.0, 2.0)
	assert_almost_eq(Terrain.height_at(g, -4.0, 0.0), 2.0, 0.01, "flattened min corner")
	assert_almost_eq(Terrain.height_at(g, 4.0, 0.0), 2.0, 0.01, "flattened max corner")
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), 2.0, 0.01, "flattened centre")

func test_carve_cutout_records_suppression() -> void:
	var g := Terrain.build_grid(_ramp_img(), 2.0, 4.0, 0.0, 10.0)
	Terrain.carve_cutout(g, -1.0, 1.0, -1.0, 1.0, -100.0)
	assert_almost_eq(Terrain.height_at(g, 0.0, 0.0), -100.0, 0.01, "inside cutout suppressed")
	assert_true(Terrain.height_at(g, 4.0, 0.0) > 5.0, "outside cutout untouched")
