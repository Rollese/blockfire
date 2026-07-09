class_name MeshMerge
extends Object
## Draw-call optimiser for procedural kit nodes. A TreeKit tree is ~50 discrete MeshInstance3D nodes
## (trunk + limbs + dozens of alpha-cutout frond quads), each its own draw call — ~5.8k draw calls for a
## town's worth of trees, murderous on an iGPU. Every frond shares one of a handful of CACHED materials
## (4 leaf variants + 1 bark), so all of a tree's meshes can be baked into ONE MeshInstance3D per
## material via SurfaceTool.append_from (which transforms each source surface into the merged mesh).
## Result: ~5 draw calls per tree, byte-identical geometry, same materials (so the pixel-cutout /
## NEAREST / double-sided look is untouched). Presentation-only (AGENTS.md §7) — no sim, no collision.
##
## Contract: TreeKit/RockKit keep building DISCRETE, individually-named + unit-tested nodes; the renderer
## calls this at scenery-build time (once, at map load) to collapse them for the GPU. It only touches
## MeshInstance3D nodes that carry a `material_override` (all TreeKit geometry does); anything else
## (GLB props whose materials are per-surface overrides) is left exactly as-is.

## Collapse every material_override-skinned MeshInstance3D under `root` into one merged MeshInstance3D
## per distinct material, baking each source node's transform (relative to `root`) into the merged mesh.
## Mutates `root` in place: merged instances replace the originals as direct children. Non-mergeable
## nodes (no mesh, or no material_override) are left untouched. Safe to call on any Node3D.
static func merge_by_material(root: Node3D) -> void:
	if root == null:
		return
	# Gather (mesh_instance, xform-relative-to-root) for every skinnable leaf.
	var jobs: Array = []
	_gather(root, Transform3D.IDENTITY, root, jobs)
	if jobs.size() < 2:
		return   # nothing to gain

	# Group by material (stable insertion order for deterministic output). Preserve first-seen material
	# object per group so the merged instance keeps the exact same cutout/NEAREST material.
	var order: Array = []                 # Array[Material], first-seen order
	var by_mat: Dictionary = {}           # material instance id -> { "mat": Material, "st": SurfaceTool }
	for job: Dictionary in jobs:
		var mi: MeshInstance3D = job["mi"]
		var xform: Transform3D = job["xform"]
		var mesh: Mesh = mi.mesh
		var mat: Material = mi.material_override
		for si in mesh.get_surface_count():
			var key := mat.get_instance_id()
			if not by_mat.has(key):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				by_mat[key] = {"mat": mat, "st": st}
				order.append(key)
			(by_mat[key]["st"] as SurfaceTool).append_from(mesh, si, xform)

	# Detach + free the originals (guard against a job whose ancestor was already freed), then attach one
	# merged instance per material group. remove_child first so get_children() reflects the merge at once.
	for job: Dictionary in jobs:
		var mi: MeshInstance3D = job["mi"]
		if not is_instance_valid(mi) or mi.is_queued_for_deletion():
			continue
		var p := mi.get_parent()
		if p != null:
			p.remove_child(mi)
		mi.queue_free()
	var idx := 0
	for key: int in order:
		var entry: Dictionary = by_mat[key]
		var merged := (entry["st"] as SurfaceTool).commit()
		if merged == null:
			continue
		var out := MeshInstance3D.new()
		out.name = "merged_%d" % idx
		out.mesh = merged
		out.material_override = entry["mat"] as Material
		root.add_child(out)
		idx += 1


## Recursively collect MeshInstance3D nodes that carry a mesh + a material_override, with the transform
## from each node's local space up to `root`. GLB props (per-surface materials, no override) are skipped
## so they keep their own materials/structure.
static func _gather(node: Node, xform_to_root: Transform3D, root: Node, jobs: Array) -> void:
	var here := xform_to_root
	if node != root and node is Node3D:
		here = xform_to_root * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null and mi.material_override != null:
			jobs.append({"mi": mi, "xform": here})
	for child in node.get_children():
		_gather(child, here, root, jobs)
