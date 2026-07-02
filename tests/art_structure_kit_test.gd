extends TestCase

func test_wall_is_full_height_sandbag_is_half() -> void:
	var wall_h := StructureKit.aabb(autofree(StructureKit.build("wall", 3))).size.y
	var bag_h := StructureKit.aabb(autofree(StructureKit.build("sandbag", 3))).size.y
	assert_true(wall_h > bag_h, "full-height wall taller than half-height sandbag")
	assert_almost_eq(bag_h, wall_h * 0.5, 0.4, "sandbag roughly half the wall height")

func test_heavy_damage_is_darker_than_pristine() -> void:
	var pristine := _albedo(autofree(StructureKit.build("wall", 3)))
	var heavy := _albedo(autofree(StructureKit.build("wall", 0)))
	assert_true(heavy.v < pristine.v, "bucket 0 darker than bucket 3")

func test_unknown_piece_falls_back_to_wall() -> void:
	assert_true(autofree(StructureKit.build("mystery", 3)) is Node3D, "unknown id still builds")

func test_fob_is_a_wide_low_bunker() -> void:
	# M12-P3: the FOB must read as a squad bunker, not a thin wall — wider and deeper than a wall,
	# and not taller than a wall (a low fortified emplacement).
	var fob := StructureKit.aabb(autofree(StructureKit.build("fob", 3)))
	var wall := StructureKit.aabb(autofree(StructureKit.build("wall", 3)))
	assert_true(fob.size.x > wall.size.x, "FOB wider than a wall")
	assert_true(fob.size.z > wall.size.z, "FOB deeper than a wall")
	assert_true(fob.size.y <= wall.size.y + 0.6, "FOB is a low bunker, not a tower")

func test_heavy_barricade_is_thicker_than_a_wall() -> void:
	var bar := StructureKit.aabb(autofree(StructureKit.build("heavy_barricade", 3)))
	var wall := StructureKit.aabb(autofree(StructureKit.build("wall", 3)))
	assert_true(bar.size.z > wall.size.z, "heavy barricade deeper/thicker than a wall")

func _albedo(node: Node3D) -> Color:
	for c in node.get_children():
		if c is MeshInstance3D:
			return ((c as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
	return Color.BLACK
