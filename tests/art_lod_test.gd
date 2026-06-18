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
