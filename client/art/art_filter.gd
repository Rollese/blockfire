class_name ArtFilter
extends Object
## Walk a built node tree and force every mesh material to NEAREST texture filtering,
## for the game-wide pixel-cutout look. Client-only presentation (AGENTS.md §7).
## Procedural kits set the filter inline at creation; this helper is for GLB-loaded
## models whose materials are baked LINEAR by the glTF importer.

## Returns the number of materials actually switched (already-NEAREST materials are left alone and
## not counted). Idempotent: a second call over the same tree returns 0.
static func apply_nearest(root: Node) -> int:
	if root == null:
		return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.material_override is BaseMaterial3D:
				count += _set_nearest(mi.material_override as BaseMaterial3D)
			var surfaces := 0
			if mi.mesh != null:
				surfaces = mi.mesh.get_surface_count()
			for s in surfaces:
				var m := mi.get_surface_override_material(s)
				if m == null and mi.mesh != null:
					m = mi.mesh.surface_get_material(s)
				if m is BaseMaterial3D:
					count += _set_nearest(m as BaseMaterial3D)
	return count

## Force NEAREST filtering; returns 1 if the value actually changed, else 0.
static func _set_nearest(mat: BaseMaterial3D) -> int:
	if mat.texture_filter == BaseMaterial3D.TEXTURE_FILTER_NEAREST:
		return 0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return 1
