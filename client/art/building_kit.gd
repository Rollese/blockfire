class_name BuildingKit
extends Object
## Procedural low-poly geometry for M11 building pieces. Presentation-only, no team-tint. Keyed by
## piece id + damage bucket (3 pristine .. 0 heavy), mirroring StructureKit's damage read.

const CELL := 2.0  # BuildGrid.CELL_SIZE

static func build(piece_id: String, bucket: int) -> Node3D:
	var root := Node3D.new()
	match piece_id:
		"bcolumn":
			root.add_child(_box("Col", Vector3(0.5, CELL, 0.5), Vector3(0, CELL * 0.5, 0), bucket, Color(0.55, 0.55, 0.58)))
		"bfloor":
			root.add_child(_box("Floor", Vector3(CELL, 0.3, CELL), Vector3(0, 0.15, 0), bucket, Color(0.6, 0.58, 0.55)))
		"brailing":
			root.add_child(_box("Rail", Vector3(CELL, 0.1, 0.1), Vector3(0, CELL * 0.5, 0), bucket, Color(0.5, 0.5, 0.5)))
		"prop_crate":
			root.add_child(_box("Crate", Vector3(0.9, 0.9, 0.9), Vector3(0, 0.45, 0), bucket, Color(0.45, 0.32, 0.18)))
		"bwall_window":
			root.add_child(_box("Sill", Vector3(CELL, CELL * 0.35, 0.3), Vector3(0, CELL * 0.18, 0), bucket, Color(0.62, 0.62, 0.62)))
			root.add_child(_box("Lintel", Vector3(CELL, CELL * 0.3, 0.3), Vector3(0, CELL * 0.85, 0), bucket, Color(0.62, 0.62, 0.62)))
		"bwall_door":
			root.add_child(_box("JambL", Vector3(CELL * 0.3, CELL, 0.3), Vector3(-CELL * 0.35, CELL * 0.5, 0), bucket, Color(0.62, 0.62, 0.62)))
			root.add_child(_box("JambR", Vector3(CELL * 0.3, CELL, 0.3), Vector3(CELL * 0.35, CELL * 0.5, 0), bucket, Color(0.62, 0.62, 0.62)))
			root.add_child(_box("Lintel", Vector3(CELL, CELL * 0.25, 0.3), Vector3(0, CELL * 0.88, 0), bucket, Color(0.62, 0.62, 0.62)))
		"bstair":
			for s in range(4):
				var h := CELL * (float(s) + 1.0) / 4.0
				root.add_child(_box("Step%d" % s, Vector3(CELL, CELL * 0.25, CELL / 4.0), Vector3(0, h * 0.5, -CELL * 0.5 + (float(s) + 0.5) * CELL / 4.0), bucket, Color(0.58, 0.58, 0.58)))
		_:
			# bwall and any unknown id -> solid full wall.
			root.add_child(_box("Wall", Vector3(CELL, CELL, 0.3), Vector3(0, CELL * 0.5, 0), bucket, Color(0.62, 0.62, 0.62)))
	if bucket <= 1:
		root.add_child(_box("Chip", Vector3(CELL * 0.4, CELL * 0.3, 0.35), Vector3(CELL * 0.25, CELL * 0.75, 0), bucket, Color(0.3, 0.3, 0.3)))
	return root

static func build_rubble() -> Node3D:
	var root := Node3D.new()
	root.add_child(_box("Rubble", Vector3(CELL * 1.6, CELL * 0.4, CELL * 1.6), Vector3(0, CELL * 0.2, 0), 0, Color(0.4, 0.38, 0.35)))
	return root

static func _box(node_name: String, size: Vector3, pos: Vector3, bucket: int, base: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	var f := ArtPalette.damage_tint(Color.WHITE, bucket).r
	mat.albedo_color = Color(base.r * f, base.g * f, base.b * f)
	mat.roughness = 0.9
	mi.material_override = mat
	return mi
