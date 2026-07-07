class_name StructureKit
extends Object
## Procedural blocky fortifications with per-damage-bucket tint. Presentation-only. Keyed by the
## PieceCatalog id string + StructureStore damage bucket (3 pristine .. 0 heavy).

# id -> {size, base_color}. base_color mirrors the piece's material tag.
const _SPEC := {
	# Width (x) must equal BuildGrid.CELL_SIZE (2.4) so a fortification spans its cell edge-to-edge.
	"wall":            {"size": Vector3(2.4, 2.4, 0.3), "color": ArtPalette.STRUCT_CONCRETE},
	"sandbag":         {"size": Vector3(2.4, 1.0, 0.6), "color": ArtPalette.STRUCT_METAL_THIN},
	# Large cooperative piece (M12): a thick, full-cell barricade — reads as a heavier wall.
	"heavy_barricade": {"size": Vector3(2.4, 2.4, 1.2), "color": ArtPalette.STRUCT_CONCRETE},
}

static func build(piece_id: String, bucket: int) -> Node3D:
	# M12-P3: the squad FOB gets a dedicated low bunker silhouette (placeholder), not a wall box.
	if piece_id == "fob":
		return _build_fob(bucket)
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

# M12-P3 squad FOB: a low, wide sandbag bunker (placeholder) — a fortified emplacement that reads
# as cover + a spawn point, not a wall. Four perimeter sandbag walls with a front gap (entrance) and
# a flat roof slab. Spans a single build cell (2 m) but is clearly bulkier than a fortification piece.
static func _build_fob(bucket: int) -> Node3D:
	var root := Node3D.new()
	var sand := ArtPalette.structure_material(ArtPalette.STRUCT_METAL_THIN, bucket)
	var concrete := ArtPalette.structure_material(ArtPalette.STRUCT_CONCRETE, bucket)
	var w := 2.6   # footprint width/depth (wider + deeper than a 2.0 wall)
	var h := 1.5   # low bunker wall height
	var t := 0.45  # sandbag wall thickness
	# Back + two side sandbag walls (front left open as an entrance).
	root.add_child(_box("FobBack", Vector3(w, h, t), Vector3(0, h * 0.5, -w * 0.5 + t * 0.5), sand))
	root.add_child(_box("FobLeft", Vector3(t, h, w), Vector3(-w * 0.5 + t * 0.5, h * 0.5, 0), sand))
	root.add_child(_box("FobRight", Vector3(t, h, w), Vector3(w * 0.5 - t * 0.5, h * 0.5, 0), sand))
	# Short front stubs flanking the entrance gap.
	root.add_child(_box("FobFrontL", Vector3(w * 0.32, h, t), Vector3(-w * 0.34, h * 0.5, w * 0.5 - t * 0.5), sand))
	root.add_child(_box("FobFrontR", Vector3(w * 0.32, h, t), Vector3(w * 0.34, h * 0.5, w * 0.5 - t * 0.5), sand))
	# Flat concrete roof slab on top.
	root.add_child(_box("FobRoof", Vector3(w, 0.25, w), Vector3(0, h + 0.12, 0), concrete))
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
