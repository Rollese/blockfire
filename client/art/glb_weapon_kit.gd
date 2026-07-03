class_name GlbWeaponKit
extends Object
## Loads imported Quaternius "Ultimate Guns Pack" CC0 weapon GLBs, mapped from the Weapon enum, and
## normalizes them to a consistent length + our forward axis. Presentation-only (AGENTS.md §7).
## Falls back to the procedural WeaponKit for any weapon with no GLB (e.g. RPG — the pack has no
## launcher) or on load failure, so every weapon id always renders something. Mirrors GlbCharacterKit:
## a wrapper Node3D holds the instanced model so downstream offset/rotation/scale composes cleanly.

const TARGET_LENGTH := 0.6   # metres along the longest axis (≈ procedural WeaponKit AR length)
# Quaternius guns lay the barrel along +X; our convention (procedural WeaponKit, soldier forward) is
# +Z. Yaw the wrapper so the barrel points +Z. PLAYTEST KNOB — if a model points backwards, add PI.
const MODEL_YAW := -PI / 2.0

const _PATHS := {
	Weapon.AR:     "res://assets/weapons/assault_rifle.glb",
	Weapon.SMG:    "res://assets/weapons/submachine_gun.glb",
	Weapon.DMR:    "res://assets/weapons/sniper_rifle.glb",
	Weapon.PISTOL: "res://assets/weapons/pistol.glb",
}

## Build a weapon model for the given Weapon enum id. Returns an imported GLB (normalized) for mapped
## weapons, else the procedural WeaponKit. Always returns a non-null Node3D.
static func build(weapon_id: int) -> Node3D:
	var path: String = _PATHS.get(weapon_id, "")
	if path.is_empty():
		return WeaponKit.build(weapon_id)        # RPG / unknown -> procedural (has its own warhead etc.)
	var ps := load(path) as PackedScene
	if ps == null:
		return WeaponKit.build(weapon_id)        # load/import failure -> procedural fallback
	var model := ps.instantiate() as Node3D
	# Normalize the longest dimension to TARGET_LENGTH so every gun is a consistent in-hand size.
	var sz: Vector3 = GlbCharacterKit.world_aabb(model).size
	var longest: float = maxf(sz.x, maxf(sz.y, sz.z))
	if longest > 0.001:
		var s := TARGET_LENGTH / longest
		model.scale = Vector3(s, s, s)
	# Wrap + yaw so the barrel runs along +Z (our forward), matching the procedural kit's convention.
	var wrapper := Node3D.new()
	wrapper.rotation = Vector3(0.0, MODEL_YAW, 0.0)
	wrapper.add_child(model)
	return wrapper
