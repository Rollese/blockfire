extends TestCase
## TreePool prototype-pool batcher: the PURE bucketing/transform math (headless-safe, no rendered pixels,
## AGENTS.md §10) plus the pool-build contract that lets a forest draw as a few MultiMesh instances. Guards:
## a fixed-seed pool is deterministic, materials stay a shared handful of buckets, and every placement's
## transform round-trips back to its pos/yaw/scale.

func setup() -> void:
	TreeKit.reset_cache_for_tests()
	RockKit.reset_cache_for_tests()

# --- pool build ------------------------------------------------------------

func test_pool_builds_count_prototypes_each_with_geometry() -> void:
	var pool := TreePool.build(12)
	assert_eq(pool.size(), 12, "build(12) -> 12 prototypes")
	for p: Dictionary in pool:
		var meshes: Dictionary = p["meshes"]
		assert_gt(meshes.size(), 0, "each prototype has >=1 baked mesh")
		for mat in meshes:
			assert_true(meshes[mat] is ArrayMesh, "baked bucket is an ArrayMesh")
			assert_gt((meshes[mat] as ArrayMesh).get_surface_count(), 0, "baked mesh has a surface")

func test_pool_material_buckets_are_a_shared_handful() -> void:
	# Trees share 4 frond variants + 1 bark = at most 5 distinct materials across the WHOLE pool, so the
	# forest can never explode into more than ~5 material buckets per prototype.
	var pool := TreePool.build(12)
	var keys: Dictionary = {}
	for p: Dictionary in pool:
		for mat in (p["meshes"] as Dictionary):
			keys[mat] = true
	assert_gt(keys.size(), 0, "pool uses some materials")
	assert_true(keys.size() <= 5, "<=5 distinct materials across the pool (got %d)" % keys.size())

func test_pool_build_is_deterministic() -> void:
	# Fixed seeds 0..N-1 + shared static materials -> two builds give the same per-prototype mesh count and
	# the same material key set (identity-stable singletons). Do NOT reset caches between the two builds.
	var a := TreePool.build(6)
	var b := TreePool.build(6)
	assert_eq(a.size(), b.size(), "same prototype count")
	var keys_a: Dictionary = {}
	var keys_b: Dictionary = {}
	for i in a.size():
		var ma: Dictionary = a[i]["meshes"]
		var mb: Dictionary = b[i]["meshes"]
		assert_eq(ma.size(), mb.size(), "prototype %d: same mesh/material count" % i)
		for k in ma: keys_a[k] = true
		for k in mb: keys_b[k] = true
	assert_eq(keys_a.size(), keys_b.size(), "same number of distinct material keys")
	for k in keys_a:
		assert_true(keys_b.has(k), "material key stable across builds")

func test_rock_pool_bakes_single_mesh() -> void:
	# A boulder is ONE mesh with a non-identity local transform (scale + seat offset). MeshMerge's >=2 guard
	# would skip it; TreePool must still bake it so the MultiMesh instances the seated geometry.
	var pool := TreePool.build(4, func(s: int) -> Node3D: return RockKit.build(s))
	assert_eq(pool.size(), 4, "rock pool has 4 prototypes")
	for p: Dictionary in pool:
		var meshes: Dictionary = p["meshes"]
		assert_eq(meshes.size(), 1, "rock is a single stone-material bucket")
		for mat in meshes:
			var aabb: AABB = (meshes[mat] as ArrayMesh).get_aabb()
			assert_gt(aabb.size.length(), 0.1, "baked boulder has real volume")

# --- assignment / transform math -------------------------------------------

func _placements(n_seeds: int) -> Array:
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in n_seeds:
		out.append({
			"pos": Vector3(rng.randf_range(-100, 100), rng.randf_range(0, 5), rng.randf_range(-100, 100)),
			"yaw": rng.randf_range(-PI + 0.01, PI - 0.01),
			"scale": rng.randf_range(0.8, 1.4),
			"seed": rng.randi(),
		})
	return out

func test_assign_conserves_every_placement() -> void:
	var pl := _placements(107)
	var buckets := TreePool.assign(pl, 12)
	var total := 0
	for idx in buckets:
		assert_true(idx >= 0 and idx < 12, "bucket index in [0, n)")
		total += (buckets[idx] as Array).size()
	assert_eq(total, 107, "no placement lost or duplicated across buckets")

func test_assign_is_deterministic() -> void:
	var pl := _placements(50)
	var a := TreePool.assign(pl, 12)
	var b := TreePool.assign(pl, 12)
	assert_eq(a.size(), b.size(), "same bucket set")
	for idx in a:
		assert_true(b.has(idx), "same bucket keys")
		assert_eq((a[idx] as Array).size(), (b[idx] as Array).size(), "same per-bucket counts")

func test_transform_round_trips_to_pos_yaw_scale() -> void:
	var pl := _placements(30)
	var buckets := TreePool.assign(pl, 8)
	# rebuild a seed -> placement lookup to compare each emitted transform back to its source
	var by_key: Dictionary = {}
	for p: Dictionary in pl:
		var xf := Transform3D(Basis(Vector3.UP, float(p["yaw"])).scaled(Vector3.ONE * float(p["scale"])), p["pos"] as Vector3)
		by_key[_xf_key(xf)] = p
	var checked := 0
	for idx in buckets:
		for xf: Transform3D in (buckets[idx] as Array):
			var src: Dictionary = by_key[_xf_key(xf)]
			assert_true((xf.origin - (src["pos"] as Vector3)).length() < 1e-3, "position preserved")
			var got_scale := xf.basis.get_scale()
			assert_almost_eq(got_scale.x, float(src["scale"]), 1e-3, "uniform scale preserved")
			var got_yaw := xf.basis.orthonormalized().get_euler().y
			assert_true(absf(wrapf(got_yaw - float(src["yaw"]), -PI, PI)) < 1e-3, "yaw preserved")
			checked += 1
	assert_eq(checked, 30, "every transform round-tripped")

func _xf_key(xf: Transform3D) -> String:
	return "%.3f,%.3f,%.3f" % [xf.origin.x, xf.origin.y, xf.origin.z]

func test_proto_index_is_stable_and_in_range() -> void:
	for s in [0, 1, -5, 999999, 0x60000000, -123456789]:
		var a := TreePool.proto_index(s, 12)
		var b := TreePool.proto_index(s, 12)
		assert_eq(a, b, "deterministic for seed %d" % s)
		assert_true(a >= 0 and a < 12, "in [0, n) for seed %d" % s)
	assert_eq(TreePool.proto_index(1234, 1), 0, "n=1 collapses to prototype 0")
