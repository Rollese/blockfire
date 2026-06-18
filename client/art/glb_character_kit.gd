class_name GlbCharacterKit
extends Object
## Loads the imported Kenney blocky character and normalizes it for the renderer. Presentation-only
## (AGENTS.md §7). The model is a node-transform-animated hierarchy (no skeleton); we keep one
## variant (character-a) for everyone — BattleBit single-uniform rule; friend/foe is the marker the
## renderer floats above friendlies, never body colour. The instanced model is scaled so its
## standing height matches the procedural kit's STAND_HEIGHT, so WorldRenderer's stance scaling math
## is identical for both modes.

const SCENE_PATH := "res://assets/characters/character-a.glb"
const STAND_HEIGHT := 1.8   # must equal CharacterKit.STAND_HEIGHT

static func build() -> Node3D:
	var ps := load(SCENE_PATH) as PackedScene
	var inst := ps.instantiate() as Node3D
	# Normalize height: the raw model is authored at its own scale; fit its AABB height to STAND_HEIGHT.
	var raw := world_aabb(inst)
	if raw.size.y > 0.001:
		var s := STAND_HEIGHT / raw.size.y
		inst.scale = Vector3(s, s, s)
	return inst

## The model's AnimationPlayer (direct child of the instanced root).
static func anim_player(node: Node3D) -> AnimationPlayer:
	return node.get_node_or_null("AnimationPlayer") as AnimationPlayer

## Recursive union of every MeshInstance3D AABB in world space (root treated as world origin).
## Headless-safe (mesh geometry only; no rendering context). Used to normalize height.
## When not in a SceneTree, composes transforms manually including root's own scale/position.
static func world_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var local: AABB = mi.mesh.get_aabb()
			var xf: Transform3D
			if mi.is_inside_tree():
				xf = mi.global_transform
			else:
				# Full transform from mesh up through and including root.
				xf = _full_xform(root, mi)
			var box := xf * local
			if first:
				out = box; first = false
			else:
				out = out.merge(box)
		for c in n.get_children():
			stack.append(c)
	return out

static func _full_xform(root: Node3D, target: Node3D) -> Transform3D:
	# Compose transforms from target up to and including root, when not yet in a SceneTree.
	var xf := Transform3D.IDENTITY
	var n: Node = target
	while n != null:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		if n == root:
			break
		n = n.get_parent()
	return xf
