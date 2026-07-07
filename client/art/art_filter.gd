class_name ArtFilter
extends Object
## Walk a built node tree and force every mesh material to NEAREST texture filtering,
## for the game-wide pixel-cutout look. Client-only presentation (AGENTS.md §7).
## Procedural kits set the filter inline at creation; this helper is for GLB-loaded
## models whose materials are baked LINEAR by the glTF importer.

## Returns the number of materials switched. Idempotent.
static func apply_nearest(root: Node) -> int:
	var count := 0
	for node in _iter(root):
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.material_override is BaseMaterial3D:
				(mi.material_override as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				count += 1
			var surfaces := 0
			if mi.mesh != null:
				surfaces = mi.mesh.get_surface_count()
			for s in surfaces:
				var m := mi.get_surface_override_material(s)
				if m == null and mi.mesh != null:
					m = mi.mesh.surface_get_material(s)
				if m is BaseMaterial3D:
					(m as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
					count += 1
	return count

static func _iter(root: Node) -> Array:
	var out: Array = [root]
	for c in root.get_children():
		out.append_array(_iter(c))
	return out
