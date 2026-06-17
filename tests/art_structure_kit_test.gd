extends TestCase

func test_wall_is_full_height_sandbag_is_half() -> void:
	var wall_h := StructureKit.aabb(StructureKit.build("wall", 3)).size.y
	var bag_h := StructureKit.aabb(StructureKit.build("sandbag", 3)).size.y
	assert_true(wall_h > bag_h, "full-height wall taller than half-height sandbag")
	assert_almost_eq(bag_h, wall_h * 0.5, 0.4, "sandbag roughly half the wall height")

func test_heavy_damage_is_darker_than_pristine() -> void:
	var pristine := _albedo(StructureKit.build("wall", 3))
	var heavy := _albedo(StructureKit.build("wall", 0))
	assert_true(heavy.v < pristine.v, "bucket 0 darker than bucket 3")

func test_unknown_piece_falls_back_to_wall() -> void:
	assert_true(StructureKit.build("mystery", 3) is Node3D, "unknown id still builds")

func _albedo(node: Node3D) -> Color:
	for c in node.get_children():
		if c is MeshInstance3D:
			return ((c as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
	return Color.BLACK
