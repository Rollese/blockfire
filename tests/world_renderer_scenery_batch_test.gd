extends TestCase
## Scenery MultiMesh batching (trees/rocks): the renderer's _build_scenery_batch must turn a list of
## placements into a HANDFUL of MultiMeshInstance3D children (one per non-empty prototype×material bucket),
## each carrying the kit's shared material_override and a map-spanning custom_aabb with NO visibility_range
## (node-origin gotcha). Headless-safe: asserts node/MultiMesh structure, never rendered pixels.

func setup() -> void:
	TreeKit.reset_cache_for_tests()
	RockKit.reset_cache_for_tests()

func _placements(n: int) -> Array:
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		out.append({
			"pos": Vector3(rng.randf_range(-150, 150), rng.randf_range(0, 4), rng.randf_range(-150, 150)),
			"yaw": rng.randf_range(0.0, TAU),
			"scale": rng.randf_range(0.8, 1.4),
			"seed": rng.randi(),
		})
	return out

func _mmis(r: WorldRenderer) -> Array:
	var out: Array = []
	for c in r.get_children():
		if c is MultiMeshInstance3D:
			out.append(c)
	return out

func test_trees_batch_into_a_handful_of_multimeshes() -> void:
	var r: WorldRenderer = autofree(WorldRenderer.new())
	var pl := _placements(107)
	r._build_scenery_batch(pl, 12, func(s: int) -> Node3D: return TreeKit.build(s), 200.0)
	var mmis := _mmis(r)
	assert_gt(mmis.size(), 0, "batching produced MultiMesh instances")
	# 12 prototypes x <=5 materials — a handful, not one-per-tree.
	assert_true(mmis.size() <= 60, "trees collapse to <=60 draws (got %d), far below 107*5" % mmis.size())
	# A tree draws as several meshes (bark + frond variants) at ONE transform, so instance_count is counted
	# once per material of a placement's prototype. Bark (the single opaque material) appears in exactly one
	# bucket per prototype, so summing bark buckets' instance_count == every placement exactly once.
	var bark_total := 0
	for mmi: MultiMeshInstance3D in mmis:
		var mm: MultiMesh = mmi.multimesh
		assert_true(mm != null and mm.mesh is ArrayMesh, "MultiMesh has a baked ArrayMesh")
		assert_eq(mm.transform_format, MultiMesh.TRANSFORM_3D, "3D transform format")
		assert_ne(mmi.material_override, null, "material_override carries the kit's shared material")
		# map-spanning aabb, no per-node visibility_range (would cull the whole field)
		assert_gt(mmi.custom_aabb.size.x, 100.0, "map-spanning custom_aabb")
		assert_true(mmi.visibility_range_end == 0.0, "no visibility_range on a map-wide MultiMesh node")
		# trees deliberately keep shadow casting (grass forces OFF; a copy-paste must not silently drop it)
		assert_eq(mmi.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "batched trees still cast shadows")
		var m := mmi.material_override
		if m is StandardMaterial3D and (m as StandardMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			bark_total += mm.instance_count
	assert_eq(bark_total, 107, "every placement instanced exactly once (via its prototype's bark bucket)")

func test_frond_material_look_is_preserved() -> void:
	var r: WorldRenderer = autofree(WorldRenderer.new())
	r._build_scenery_batch(_placements(40), 12, func(s: int) -> Node3D: return TreeKit.build(s), 200.0)
	var saw_scissor := false
	for mmi: MultiMeshInstance3D in _mmis(r):
		var m := mmi.material_override
		if m is StandardMaterial3D and (m as StandardMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			var sm := m as StandardMaterial3D
			assert_eq(sm.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "fronds stay NEAREST")
			assert_eq(sm.cull_mode, BaseMaterial3D.CULL_DISABLED, "fronds stay double-sided")
			saw_scissor = true
	assert_true(saw_scissor, "the pixel-cutout frond material survives batching")

func test_rocks_batch_over_a_small_pool() -> void:
	var r: WorldRenderer = autofree(WorldRenderer.new())
	r._build_scenery_batch(_placements(55), 8, func(s: int) -> Node3D: return RockKit.build(s), 200.0)
	var mmis := _mmis(r)
	assert_gt(mmis.size(), 0, "rocks batched")
	assert_true(mmis.size() <= 8, "rocks collapse to <=8 draws (one stone bucket per prototype), got %d" % mmis.size())
	var total := 0
	for mmi: MultiMeshInstance3D in mmis:
		total += (mmi.multimesh as MultiMesh).instance_count
	assert_eq(total, 55, "all rocks instanced")

func test_empty_placements_is_a_noop() -> void:
	var r: WorldRenderer = autofree(WorldRenderer.new())
	r._build_scenery_batch([], 12, func(s: int) -> Node3D: return TreeKit.build(s), 200.0)
	assert_eq(_mmis(r).size(), 0, "no placements -> no MultiMesh nodes")
