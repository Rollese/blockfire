class_name GlbWeaponKit
extends Object
## Loads imported Quaternius "Ultimate Guns Pack" CC0 weapon GLBs, mapped from the Weapon enum, and
## normalizes them to a consistent length + our forward axis. Presentation-only (AGENTS.md §7).
## Falls back to the procedural WeaponKit for any weapon with no GLB (e.g. RPG — the pack has no
## launcher) or on load failure, so every weapon id always renders something. Mirrors GlbCharacterKit:
## a wrapper Node3D holds the instanced model so downstream offset/rotation/scale composes cleanly.

const TARGET_LENGTH := 0.6   # metres along the longest axis (≈ procedural WeaponKit AR length)
# Different CC0 packs lay the barrel along different axes (Quaternius = +X, Broken Vector = +Y), so we
# don't hardcode one pack's convention: detect the longest AABB axis (the barrel) and rotate the
# wrapper so it runs along +Z — our forward (procedural WeaponKit / soldier forward; the first-person
# viewmodel then applies VM_YAW=PI to face the -Z camera). PLAYTEST KNOB — if a model points
# muzzle-backward, negate the matching angle below.
const YAW_FROM_X := -PI / 2.0   # +X barrel -> +Z (Quaternius pack)
const PITCH_FROM_Y := -PI / 2.0  # +Y barrel -> +Z (Broken Vector pack)

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
	# Wrap + rotate so the barrel (longest axis) runs along +Z (our forward), matching the procedural
	# kit's convention — pack-agnostic (see YAW_FROM_X / PITCH_FROM_Y).
	var wrapper := Node3D.new()
	if sz.y >= sz.x and sz.y >= sz.z:
		# +Y barrel (Broken Vector): pitch it onto +Z, THEN roll 180° about the barrel so the gun is
		# right-side-up (the pitch alone leaves it upside-down). Composed as a Basis rather than Euler
		# because Godot's YXZ Euler order applies the roll in model space, not about the final barrel.
		wrapper.transform = Transform3D(
			Basis(Vector3(0, 0, 1), PI) * Basis(Vector3(1, 0, 0), PITCH_FROM_Y), Vector3.ZERO)
	elif sz.x >= sz.z:
		wrapper.rotation = Vector3(0.0, YAW_FROM_X, 0.0)     # +X barrel (Quaternius) -> +Z
	# else: already longest along Z -> forward, no rotation
	wrapper.add_child(model)
	return wrapper
