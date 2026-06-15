class_name Combat
extends Object
## Deterministic, server-authoritative shot reconstruction + damage math. The server
## never trusts a client-supplied ray; it rebuilds the ray from look angles + a seed
## derived from (shooter, fire_tick, shot_index). Client can reproduce it identically.

static func _forward(yaw: float, pitch: float) -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))

static func _seed(shooter_id: int, fire_tick: int, shot_index: int) -> int:
	return (shooter_id * 73856093) ^ (fire_tick * 19349663) ^ ((shot_index + 1) * 83492791)

## Returns {origin, dir}. lean: -1 left, 0 none, +1 right. moving adds spread. `prone` enables the
## bipod zero-spread case; `def` (optional) is an effective weapon def (Weapon.effective_def) used
## instead of the base when non-empty — this is how loadout attachments reach the shot.
static func reconstruct_ray(weapon_id: int, eye: Vector3, yaw: float, pitch: float,
		lean: int, shooter_id: int, fire_tick: int, shot_index: int, moving: bool,
		prone: bool = false, def: Dictionary = {}) -> Dictionary:
	var w: Dictionary = def if not def.is_empty() else Weapon.get_def(weapon_id)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed(shooter_id, fire_tick, shot_index)

	var climb := deg_to_rad(w["recoil_pitch_deg"]) * minf(float(shot_index), 8.0)
	var aim_pitch := pitch + climb

	var spread := deg_to_rad(w["spread_base_deg"] + w["spread_bloom_deg"] * minf(float(shot_index), 6.0))
	if moving:
		spread += deg_to_rad(1.5) * float(w.get("move_spread_mult", 1.0))
	if prone and bool(w.get("prone_spread_zero", false)):
		spread = 0.0
	var ang := rng.randf_range(0.0, TAU)
	var mag := rng.randf() * spread

	var dir := _forward(yaw + cos(ang) * mag, aim_pitch + sin(ang) * mag).normalized()

	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var origin := eye + right * (Stance.LEAN_OFFSET * float(lean))
	return {"origin": origin, "dir": dir}

static func damage_for(weapon_id: int, headshot: bool, distance: float, def: Dictionary = {}) -> int:
	var w: Dictionary = def if not def.is_empty() else Weapon.get_def(weapon_id)
	if distance > w["range_m"]:
		return 0
	var dmg := float(w["damage_body"])
	if headshot:
		dmg *= w["headshot_mult"]
	return int(round(dmg))

## Split a shot at a penetrable piece. `piece_body` is the weapon body damage applied to the
## piece; `enemy_damage` is the already-resolved damage (incl. headshot/range) the target beyond
## would take with no obstruction. Returns {piece_damage, exit_damage}: the piece takes
## body*absorption, the target beyond takes enemy_damage*transmit. The caller enforces the 1-pen
## cap and the "only continue if the piece survives" rule (spec §"Bullet penetration").
static func apply_penetration(piece_body: int, enemy_damage: int, absorption: float, transmit: float) -> Dictionary:
	return {
		"piece_damage": int(round(float(piece_body) * absorption)),
		"exit_damage": int(round(float(enemy_damage) * transmit)),
	}
