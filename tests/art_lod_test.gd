extends TestCase

func test_level_for_distance_buckets() -> void:
	assert_eq(Lod.level_for(0.0), 0, "point-blank = full detail (level 0)")
	assert_eq(Lod.level_for(Lod.MID_END - 1.0), 0, "just inside MID_END = full")
	assert_eq(Lod.level_for(Lod.MID_END + 1.0), 1, "past MID_END = body-only (level 1)")
	assert_eq(Lod.level_for(Lod.FAR_BEGIN + 1.0), 2, "past FAR_BEGIN = proxy (level 2)")

func test_thresholds_are_ordered() -> void:
	assert_true(Lod.MID_END < Lod.FAR_BEGIN, "detail sheds before the body demotes to a proxy")

func test_tier_of_part_names() -> void:
	assert_eq(Lod.tier_of("Helmet"), 1, "helmet is a small detail part")
	assert_eq(Lod.tier_of("GunMount"), 1, "gun is a small detail part")
	assert_eq(Lod.tier_of("ArmL"), 1, "arms are detail parts")
	assert_eq(Lod.tier_of("Torso"), 0, "torso is silhouette/body (tier 0)")
	assert_eq(Lod.tier_of("Legs"), 0, "legs are silhouette/body (tier 0)")
	assert_eq(Lod.tier_of("SomeImportedMeshName"), 0, "unknown meshes default to the body tier")

func test_apply_sets_ranges_by_tier_and_adds_proxy() -> void:
	var soldier := CharacterKit.build()
	Lod.apply_to_character(soldier)
	assert_true(soldier.has_node("LodProxy"), "a single proxy box is added")
	var proxy := soldier.get_node("LodProxy") as MeshInstance3D
	assert_almost_eq(proxy.visibility_range_begin, Lod.FAR_BEGIN, 0.01, "proxy begins at FAR_BEGIN")
	var helmet := soldier.get_node("Helmet") as MeshInstance3D
	var torso := soldier.get_node("Torso") as MeshInstance3D
	assert_almost_eq(helmet.visibility_range_end, Lod.MID_END, 0.01, "detail part ends at MID_END")
	assert_almost_eq(torso.visibility_range_end, Lod.FAR_BEGIN, 0.01, "body part ends at FAR_BEGIN")

func test_apply_is_idempotent() -> void:
	var soldier := CharacterKit.build()
	Lod.apply_to_character(soldier)
	Lod.apply_to_character(soldier)
	var proxies := 0
	for c in soldier.get_children():
		if c is MeshInstance3D and c.name == "LodProxy":
			proxies += 1
	assert_eq(proxies, 1, "re-applying does not add a second proxy")

func test_apply_recurses_into_nested_meshes() -> void:
	var root := Node3D.new()
	var mid := Node3D.new()
	root.add_child(mid)
	var mesh := MeshInstance3D.new()
	mesh.name = "Torso"
	mesh.mesh = BoxMesh.new()
	mid.add_child(mesh)
	Lod.apply_to_character(root)
	assert_almost_eq(mesh.visibility_range_end, Lod.FAR_BEGIN, 0.01, "nested mesh gets a range too")
	assert_true(root.has_node("LodProxy"), "proxy added to the root even when meshes are nested")

func test_active_part_count_drops_with_distance() -> void:
	var soldier := CharacterKit.build()   # 7 parts: Legs Torso ArmL ArmR Head Helmet GunMount
	Lod.apply_to_character(soldier)
	var near := Lod.active_part_count(soldier, 10.0)
	var mid := Lod.active_part_count(soldier, (Lod.MID_END + Lod.FAR_BEGIN) * 0.5)
	var far := Lod.active_part_count(soldier, Lod.FAR_BEGIN + 30.0)
	assert_eq(near, 7, "all 7 parts draw up close (proxy off)")
	assert_eq(mid, 2, "only the 2 body parts draw at mid range (5 detail parts shed, proxy off)")
	assert_eq(far, 1, "only the proxy box draws far away")
	assert_true(far < mid and mid < near, "cost is monotonically non-increasing with distance")

func test_128_soldiers_far_cost_is_a_small_fraction_of_near() -> void:
	var near_total := 0
	var far_total := 0
	for _i in 128:
		var soldier := CharacterKit.build()
		Lod.apply_to_character(soldier)
		near_total += Lod.active_part_count(soldier, 10.0)
		far_total += Lod.active_part_count(soldier, Lod.FAR_BEGIN + 50.0)
	assert_eq(near_total, 128 * 7, "worst case: every soldier at full detail")
	assert_eq(far_total, 128 * 1, "all-far: one proxy box each")
	assert_true(far_total <= near_total / 5, "far-scene draw cost <= 1/5 of the all-near worst case")
