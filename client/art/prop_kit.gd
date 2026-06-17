class_name PropKit
extends Object
## Cosmetic map set-dressing props (no gameplay collision — that stays sim-side). Presentation-only.

static func build(prop_name: String) -> Node3D:
	var root := Node3D.new()
	match prop_name:
		"barrel":
			var b := MeshInstance3D.new()
			b.name = "Barrel"
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.3
			cyl.bottom_radius = 0.3
			cyl.height = 0.9
			b.mesh = cyl
			b.position = Vector3(0, 0.45, 0)
			b.material_override = ArtPalette.structure_material(ArtPalette.STRUCT_METAL_THIN, 2)
			root.add_child(b)
		"barrier":
			root.add_child(_box("Barrier", Vector3(1.6, 1.0, 0.25), Vector3(0, 0.5, 0),
				ArtPalette.structure_material(ArtPalette.STRUCT_CONCRETE, 3)))
		_:  # crate (default)
			root.add_child(_box("Crate", Vector3(0.8, 0.8, 0.8), Vector3(0, 0.4, 0),
				ArtPalette.structure_material(ArtPalette.STRUCT_METAL_THIN, 3)))
	return root

static func _box(name: String, size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	return mi

static func aabb(root: Node3D) -> AABB:
	return CharacterKit.aabb(root)
