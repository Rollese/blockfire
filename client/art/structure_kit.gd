class_name StructureKit
extends Object
## Procedural blocky fortifications with per-damage-bucket tint. Presentation-only. Keyed by the
## PieceCatalog id string + StructureStore damage bucket (3 pristine .. 0 heavy).

# id -> {size, base_color}. base_color mirrors the piece's material tag.
const _SPEC := {
	"wall":    {"size": Vector3(2.0, 2.4, 0.3), "color": ArtPalette.STRUCT_CONCRETE},
	"sandbag": {"size": Vector3(2.0, 1.0, 0.6), "color": ArtPalette.STRUCT_METAL_THIN},
}

static func build(piece_id: String, bucket: int) -> Node3D:
	var spec: Dictionary = _SPEC.get(piece_id, _SPEC["wall"])
	var root := Node3D.new()
	var mat := ArtPalette.structure_material(spec["color"], bucket)
	var size: Vector3 = spec["size"]
	var body := _box("Body", size, Vector3(0, size.y * 0.5, 0), mat)
	root.add_child(body)
	# Heavy damage (bucket <= 1) adds a chipped corner block so damage reads in silhouette, not just tint.
	if bucket <= 1:
		var chip := _box("Chip", Vector3(size.x * 0.4, size.y * 0.3, size.z * 1.05),
			Vector3(size.x * 0.25, size.y * 0.85, 0), mat)
		root.add_child(chip)
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
