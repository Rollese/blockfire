class_name Lod
extends Object
## Distance level-of-detail for rendered entities (soldiers). Presentation-only (AGENTS.md §7).
## Configures Godot's built-in per-GeometryInstance3D visibility_range so small body parts cull
## with distance and the whole body demotes to one proxy box far away — the engine does the actual
## culling. All logic here is pure property-config + a pure cost proxy, so it is headless-testable.

# Camera->part distance thresholds, metres. Tunable at playtest.
const MID_END := 35.0     # tier-1 detail parts (helmet/gun/arms/head) cull beyond this
const FAR_BEGIN := 70.0   # tier-0 body parts cull here; the LodProxy box takes over

# Small detail parts (tier 1). Everything else — incl. unknown/imported mesh names — is tier 0 (body).
const DETAIL_PARTS := ["Helmet", "GunMount", "ArmL", "ArmR", "Head"]

## LOD level for a camera distance: 0 = full, 1 = body-only (detail shed), 2 = proxy box.
static func level_for(distance: float) -> int:
	if distance >= FAR_BEGIN:
		return 2
	if distance >= MID_END:
		return 1
	return 0

## Tier for a mesh by name: 1 = small detail (culls at MID_END), 0 = body/silhouette (culls at FAR_BEGIN).
static func tier_of(part_name: String) -> int:
	return 1 if DETAIL_PARTS.has(part_name) else 0

## Configure a built character root (procedural CharacterKit OR imported GLB) for distance LOD:
## every real MeshInstance3D gets a visibility_range_end by tier, and one neutral LodProxy box is
## added that begins where the body ends. Idempotent. Hard switch (no fade) for v1.
static func apply_to_character(root: Node3D) -> void:
	if root.has_node("LodProxy"):
		return
	for mi in _mesh_descendants(root):
		mi.visibility_range_end = MID_END if tier_of(mi.name) == 1 else FAR_BEGIN
	root.add_child(_proxy_box())

## Pure cost proxy: how many of root's meshes would draw at `distance` — real meshes whose
## [0, visibility_range_end) covers it, plus the proxy when distance >= its begin.
static func active_part_count(root: Node3D, distance: float) -> int:
	var n := 0
	for mi in _mesh_descendants(root):
		if mi.name == "LodProxy":
			if distance >= mi.visibility_range_begin:
				n += 1
		else:
			var end: float = mi.visibility_range_end
			if end <= 0.0 or distance < end:
				n += 1
	return n

static func _proxy_box() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "LodProxy"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.6, CharacterKit.STAND_HEIGHT, 0.4)
	mi.mesh = mesh
	mi.position = Vector3(0.0, CharacterKit.STAND_HEIGHT * 0.5, 0.0)
	mi.material_override = ArtPalette.team_material(-1)
	mi.visibility_range_begin = FAR_BEGIN
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## Every MeshInstance3D in the subtree (root included), recursive — handles nested GLB hierarchies.
static func _mesh_descendants(root: Node3D) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out
