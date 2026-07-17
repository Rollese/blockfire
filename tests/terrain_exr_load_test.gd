extends TestCase
const Terrain := preload("res://shared/sim/terrain.gd")
const HeightmapIO := preload("res://shared/mapedit/heightmap_io.gd")

const TMP := "user://m22_terrain_exr_test"

func setup() -> void:
	DirAccess.make_dir_recursive_absolute(TMP.path_join("heightmaps"))

func teardown() -> void:
	var hm := DirAccess.open(TMP.path_join("heightmaps"))
	if hm != null:
		hm.list_dir_begin()
		var f := hm.get_next()
		while f != "":
			hm.remove(TMP.path_join("heightmaps").path_join(f))
			f = hm.get_next()
		hm.list_dir_end()

# world_half 10, spacing 2 -> 11x11 samples covering [-10..10].
func _map_dict(heightmap_rel: String) -> Dictionary:
	return {
		"name": "exr_fixture",
		"world_half": 10.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 5.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -8]}, {"team": 1, "pos": [0, 0, 8]}],
		"terrain": {"heightmap": heightmap_rel, "sample_spacing": 2.0, "height_min": -10.0, "height_scale": 24.0},
	}

func test_exr_heightmap_gives_exact_heights() -> void:
	# A ramp with sub-8-bit-quantum steps. 8-bit would quantise to 24/255 = 9.4 cm; EXR must not.
	var norm := PackedFloat32Array()
	norm.resize(121)
	for zi in 11:
		for xi in 11:
			norm[zi * 11 + xi] = 0.5 + float(xi) * 0.001   # 2.4 cm steps in height terms
	HeightmapIO.save_exr_norm(norm, 11, 11, TMP.path_join("heightmaps/ramp.exr"))
	var res := MapDef.from_dict(_map_dict("heightmaps/ramp.exr"))
	assert_true(res["ok"], "fixture map parses: %s" % res["error"])
	var grid := Terrain.load_for_map(res["map"], TMP, Callable())
	assert_ne(grid, null, "EXR heightmap builds a grid")
	# sample xi=5 is world x=0; norm 0.505 -> -10 + 0.505*24 = 2.12 m
	assert_almost_eq(Terrain.height_at(grid, 0.0, 0.0), 2.12, 0.001, "exact float height, no 8-bit quantisation")
	# The 2.4 cm step between adjacent samples must SURVIVE (8-bit would collapse it to 0).
	var h5 := Terrain.height_at(grid, 0.0, 0.0)
	var h6 := Terrain.height_at(grid, 2.0, 0.0)
	assert_almost_eq(h6 - h5, 0.024, 0.001, "sub-quantum step survives -> stair-stepping fixed")

func test_legacy_png_heightmap_still_loads() -> void:
	var img := Image.create(11, 11, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	assert_eq(img.save_png(TMP.path_join("heightmaps/legacy.png")), OK, "png fixture saved")
	var res := MapDef.from_dict(_map_dict("heightmaps/legacy.png"))
	var grid := Terrain.load_for_map(res["map"], TMP, Callable())
	assert_ne(grid, null, "legacy PNG still builds a grid")
	# 0.5 (as 8-bit 128/255=0.502) -> -10 + 0.502*24 = 2.05; loose tol absorbs the 8-bit rounding.
	assert_almost_eq(Terrain.height_at(grid, 0.0, 0.0), 2.05, 0.15, "PNG map unchanged (back-compat)")

func test_dimension_mismatch_is_rejected_loudly() -> void:
	tolerate_runtime_errors()   # push_error is the point of this test
	# world_half 10 + spacing 2 implies 11x11; give it 5x5.
	var norm := PackedFloat32Array()
	norm.resize(25)
	norm.fill(0.5)
	HeightmapIO.save_exr_norm(norm, 5, 5, TMP.path_join("heightmaps/wrong.exr"))
	var res := MapDef.from_dict(_map_dict("heightmaps/wrong.exr"))
	var grid := Terrain.load_for_map(res["map"], TMP, Callable())
	assert_eq(grid, null, "a heightmap that disagrees with world_half/spacing is refused, not silently misplaced")
