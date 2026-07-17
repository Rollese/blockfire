extends TestCase
const WorldRenderer := preload("res://client/world_renderer.gd")

func _spline_map() -> MapDef:
	var res := MapDef.from_dict({
		"name": "ribbon_fixture",
		"world_half": 60.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -50]}, {"team": 1, "pos": [0, 0, 50]}],
		"roads": [{"spline": [[-40, 0], [40, 0]], "width": 8.0}],
	})
	assert_true(res["ok"], "fixture parses: %s" % res["error"])
	return res["map"]

func _count_ribbons(root: Node) -> int:
	var n := 0
	for c in root.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("RoadRibbon"):
			n += 1
	return n

func test_spline_road_builds_a_ribbon_mesh() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.build_roads(_spline_map(), null)
	assert_eq(_count_ribbons(wr), 1, "one spline road -> one ribbon node")

func test_ribbon_geometry_is_non_empty() -> void:
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.build_roads(_spline_map(), null)
	for c in wr.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("RoadRibbon"):
			var mesh: ArrayMesh = c.mesh
			assert_ne(mesh, null, "ribbon has a mesh")
			assert_gt(mesh.get_surface_count(), 0, "ribbon has a surface")
			assert_gt(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(), 0, "ribbon has vertices")
			return
	fail("no ribbon found")

func test_legacy_aabb_road_still_renders_flat_on_a_flat_map() -> void:
	var res := MapDef.from_dict({
		"name": "aabb_fixture",
		"world_half": 60.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -50]}, {"team": 1, "pos": [0, 0, 50]}],
		"roads": [{"min": [-6, 0, -40], "max": [6, 0, 40]}],
	})
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.build_roads(res["map"], null)
	var planes := 0
	for c in wr.get_children():
		if c is MeshInstance3D and c.mesh is PlaneMesh:
			planes += 1
	assert_eq(planes, 1, "legacy AABB road still renders its flat strip (back-compat)")

func test_legacy_aabb_road_is_skipped_on_a_terrain_map() -> void:
	# Established behaviour: a flat plane buries under a hill, so terrain maps skip AABB roads.
	var res := MapDef.from_dict({
		"name": "aabb_terrain_fixture",
		"world_half": 60.0,
		"points": [{"id": "A", "pos": [0, 0, 0], "radius": 10.0, "start_owner": -1}],
		"bases": [{"team": 0, "pos": [0, 0, -50]}, {"team": 1, "pos": [0, 0, 50]}],
		"roads": [{"min": [-6, 0, -40], "max": [6, 0, 40]}],
	})
	var grid := TerrainGrid.new()
	grid.cols = 3; grid.rows = 3; grid.spacing = 60.0
	grid.origin_x = -60.0; grid.origin_z = -60.0
	grid.samples = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.build_roads(res["map"], grid)
	var planes := 0
	for c in wr.get_children():
		if c is MeshInstance3D and c.mesh is PlaneMesh:
			planes += 1
	assert_eq(planes, 0, "AABB road skipped on a terrain map (unchanged behaviour)")

func test_spline_road_drapes_on_terrain() -> void:
	var grid := TerrainGrid.new()
	grid.cols = 3; grid.rows = 3; grid.spacing = 60.0
	grid.origin_x = -60.0; grid.origin_z = -60.0
	grid.samples = PackedFloat32Array([0, 0, 0, 0, 12, 0, 0, 0, 0])   # a hill at the centre
	var wr: WorldRenderer = autofree(WorldRenderer.new())
	wr.build_roads(_spline_map(), grid)
	for c in wr.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("RoadRibbon"):
			var verts: PackedVector3Array = (c.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var lo := INF
			var hi := -INF
			for v in verts:
				lo = minf(lo, v.y)
				hi = maxf(hi, v.y)
			assert_gt(hi - lo, 1.0, "ribbon y varies -> it drapes over the hill instead of lying flat")
			return
	fail("no ribbon found")
