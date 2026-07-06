extends TestCase
const StructureStore := preload("res://shared/sim/structure.gd")
const PieceCatalog := preload("res://shared/sim/piece_catalog.gd")
const Terrain := preload("res://shared/sim/terrain.gd")
const TerrainGrid := preload("res://shared/sim/terrain_grid.gd")

# A hill ridge: flat 0 except a 10 m ridge along x=0.
func _ridge() -> TerrainGrid:
	var g := TerrainGrid.new()
	g.cols = 41; g.rows = 41; g.spacing = 2.0; g.origin_x = -40.0; g.origin_z = -40.0
	var s := PackedFloat32Array(); s.resize(1681)
	for zi in 41:
		for xi in 41:
			var wx := -40.0 + float(xi) * 2.0
			s[zi*41 + xi] = 10.0 if absf(wx) < 3.0 else 0.0
	g.samples = s
	return g

func _empty_store() -> StructureStore:
	var pc := PieceCatalog.new()   # empty catalog OK for a store with no pieces
	return StructureStore.new(pc)

func test_flat_terrain_does_not_block() -> void:
	var st := _empty_store()
	st.terrain = null
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "flat terrain, no structures -> clear")

func test_hill_blocks_low_sightline() -> void:
	var st := _empty_store()
	st.terrain = _ridge()
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_true(bool(m["hit"]), "the 10 m ridge blocks a 1.6 m sightline across it")
	assert_true(float(m["dist"]) < 20.0, "blocked before reaching the far side")

func test_high_shot_clears_the_hill() -> void:
	var st := _empty_store()
	st.terrain = _ridge()
	var m := st.march(Vector3(-15, 15, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "a sightline above the ridge is clear")

func test_cutout_does_not_block() -> void:
	var st := _empty_store()
	var g := _ridge()
	Terrain.carve_cutout(g, -3.0, 3.0, -3.0, 3.0, Terrain.CUTOUT_FLOOR)
	st.terrain = g
	var m := st.march(Vector3(-15, 1.6, 0), Vector3(1,0,0), 30.0)
	assert_false(bool(m["hit"]), "a cutout through the ridge opens the sightline (tunnel)")
