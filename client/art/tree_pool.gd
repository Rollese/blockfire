class_name TreePool
extends Object
## Prototype-pool batcher for procedural scenery (trees, rocks) so a whole forest draws in a HANDFUL of
## MultiMesh instances instead of one node subtree per placement. Background:
##   * Each map tree is a unique-per-seed subtree of ~50 frond/limb MeshInstance3D; MeshMerge collapses it
##     to ~5 draws, but 107 trees still stay ~535 SEPARATE, un-cross-batched draw calls (brutal on iGPU).
##   * A naive MultiMesh is impossible: MultiMesh instances ONE shared mesh, but every tree's baked
##     geometry differs per seed.
## The fix (this module): pre-bake a small POOL of N prototype trees with FIXED seeds 0..N-1 (deterministic,
## stable forest). Assign each map placement a prototype by hashing its per-placement seed. For each
## (prototype x material) bucket, the renderer draws ONE MultiMesh of that prototype's merged mesh at every
## assigned placement's transform. Variety comes from N distinct prototypes + per-instance yaw/scale.
## Result: ~535 -> ~N*(materials-per-tree) draws (trees), and the ~55 rocks collapse to N draws.
##
## Presentation-only (AGENTS.md §7): no sim, no collision, no wire. Frond/bark materials are the SAME shared
## static singletons the discrete trees use, so the NEAREST alpha-scissor cutout + double-sided look is
## byte-identical; they key the material buckets by identity so the same material shares a bucket across
## prototypes.

## Build `count` prototypes. `builder` maps an int seed -> a freshly built kit Node3D (defaults to a
## TreeKit tree); pass `RockKit.build` (as a Callable) for a boulder pool. Each prototype is
## `{"meshes": {Material -> ArrayMesh}}`: every material_override-skinned mesh under the built node is baked
## (with its transform relative to the node root folded into the geometry) into one ArrayMesh per material.
## The built nodes are freed here; the ArrayMesh/Material resources are RefCounted and survive in the dict.
static func build(count: int, builder: Callable = Callable()) -> Array:
	if not builder.is_valid():
		builder = func(s: int) -> Node3D: return TreeKit.build(s)
	var protos: Array = []
	for i in count:
		var node: Node3D = builder.call(i)
		protos.append({"meshes": _bake_by_material(node)})
		if is_instance_valid(node):
			node.free()
	return protos

## Bake every material_override-skinned MeshInstance3D under `root` into one ArrayMesh per distinct material
## (keyed by the material's identity), folding each source node's transform-relative-to-root into the mesh.
## Mirrors MeshMerge.merge_by_material's SurfaceTool.append_from technique, but returns baked meshes instead
## of mutating the tree AND bakes even a lone mesh (MeshMerge's >=2-job guard would leave a single-mesh rock
## un-baked, dropping its local scale/seat offset). Materials are the kits' shared cached singletons, so the
## same frond/bark/stone material maps to the SAME key across every prototype.
static func _bake_by_material(root: Node3D) -> Dictionary:
	var jobs: Array = []
	_gather(root, Transform3D.IDENTITY, root, jobs)
	var order: Array = []            # Array[Material], first-seen order (stable output)
	var by_mat: Dictionary = {}      # Material -> SurfaceTool
	for job: Dictionary in jobs:
		var mi: MeshInstance3D = job["mi"]
		var xform: Transform3D = job["xform"]
		var mesh: Mesh = mi.mesh
		var mat: Material = mi.material_override
		if mesh == null or mat == null:
			continue
		for si in mesh.get_surface_count():
			if not by_mat.has(mat):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				by_mat[mat] = st
				order.append(mat)
			(by_mat[mat] as SurfaceTool).append_from(mesh, si, xform)
	var out: Dictionary = {}
	for mat: Material in order:
		var merged := (by_mat[mat] as SurfaceTool).commit()
		if merged != null:
			out[mat] = merged
	return out

## Recursively collect (MeshInstance3D, transform-to-root) for every mesh that carries a material_override.
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

## Pure bucketing math (unit-tested headless). Assign each placement to a prototype by hashing its seed,
## and compose its world Transform3D = translate(pos) * rotate_y(yaw) * uniform_scale. Returns
## {prototype_index -> Array[Transform3D]}. `placements` is a list of {pos:Vector3, yaw:float, scale:float,
## seed:int}. Total transforms out == placements in (nothing lost/added); fully deterministic.
static func assign(placements: Array, n: int) -> Dictionary:
	var buckets: Dictionary = {}
	for pl: Dictionary in placements:
		var idx := proto_index(int(pl["seed"]), n)
		var arr: Array = buckets.get(idx, [])
		var basis := Basis(Vector3.UP, float(pl["yaw"])).scaled(Vector3.ONE * float(pl["scale"]))
		arr.append(Transform3D(basis, pl["pos"] as Vector3))
		buckets[idx] = arr
	return buckets

## Deterministic placement-seed -> prototype index in [0, n). Re-hashes the (already position-hashed) seed
## so neighbouring placements don't stripe onto the same prototype.
static func proto_index(seed: int, n: int) -> int:
	if n <= 1:
		return 0
	return posmod(hash(seed), n)
