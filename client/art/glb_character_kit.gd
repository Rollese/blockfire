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
const HAND_NODE := "arm-right"                  # the GLB node the weapon is parented under (the hand)
# In-hand placement, in the hand node's LOCAL space. PLAYTEST KNOBS — tune by eye, not derivable
# headlessly (depends on the model's normalization scale + arm axis). Starting guesses below.
const WEAPON_OFFSET := Vector3(0.0, -0.35, 0.15)   # down toward the hand, slightly forward
const WEAPON_ROT := Vector3(0.0, 0.0, 0.0)         # barrel orientation (radians); tune at playtest
const WEAPON_SCALE := 1.0                          # compensate for the model's normalization scale

static func build() -> Node3D:
	var ps := load(SCENE_PATH) as PackedScene
	if ps == null:
		# Imported scene missing/stale — fall back to the procedural kit instead of crashing the
		# client on the first remote spawn (mirrors GlbWeaponKit's null-guard fallback).
		push_warning("[GlbCharacterKit] %s failed to load; using procedural CharacterKit" % SCENE_PATH)
		return CharacterKit.build()
	var model := ps.instantiate() as Node3D
	if model == null:
		return CharacterKit.build()
	# Normalize the model's own height to STAND_HEIGHT.
	var raw := world_aabb(model)
	if raw.size.y > 0.001:
		var s := STAND_HEIGHT / raw.size.y
		model.scale = Vector3(s, s, s)
	# Wrap in an identity-scale outer Node3D so the renderer's per-frame stance scaling composes
	# with (instead of overwriting) the normalization scale. The wrapper behaves like the procedural
	# CharacterKit root: natural scale 1, natural height == STAND_HEIGHT.
	var wrapper := Node3D.new()
	wrapper.add_child(model)
	attach_weapon(wrapper, Weapon.AR)
	return wrapper

## Parent a WeaponKit weapon under the model's hand node so the soldier visibly carries it. The GLB
## is node-transform animated (no skeleton), so a child of the hand node follows the hand through
## every clip. Returns true if attached. Placement is a playtest knob (see consts). Presentation-only.
static func attach_weapon(root: Node3D, weapon_id: int) -> bool:
	var hand := root.find_child(HAND_NODE, true, false)
	if hand == null:
		return false
	var weapon := GlbWeaponKit.build(weapon_id)
	weapon.name = "HeldWeapon"
	weapon.position = WEAPON_OFFSET
	weapon.rotation = WEAPON_ROT
	weapon.scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE)
	hand.add_child(weapon)
	return true

## The model's AnimationPlayer, searched recursively (it is now nested under the wrapper).
static func anim_player(node: Node3D) -> AnimationPlayer:
	return node.find_child("AnimationPlayer", true, false) as AnimationPlayer

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
