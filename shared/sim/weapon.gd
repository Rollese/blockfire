class_name Weapon
extends Object
## Data-driven hit-scan weapon registry. M2: flat damage to range, then 0.

enum { AR = 0, SMG = 1, DMR = 2, RPG = 3, PISTOL = 4 }

const MODE_AUTO := 0
const MODE_SEMI := 1
const MODE_BURST := 2
const DEFAULT_BURST := 3

const _DEFS := {
	AR:     {"name": "AR",     "damage_body": 25, "headshot_mult": 2.0, "rpm": 600, "mag_size": 30, "reload_secs": 2.2, "spread_base_deg": 0.6, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.4, "range_m": 300.0, "muzzle_velocity": 250.0, "gravity_scale": 0.5,  "fire_modes": [MODE_AUTO, MODE_SEMI, MODE_BURST], "burst_count": 3},
	SMG:    {"name": "SMG",    "damage_body": 18, "headshot_mult": 1.8, "rpm": 900, "mag_size": 35, "reload_secs": 2.0, "spread_base_deg": 1.0, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.3, "range_m": 150.0, "muzzle_velocity": 180.0, "gravity_scale": 0.7,  "fire_modes": [MODE_AUTO, MODE_SEMI], "burst_count": 3},
	DMR:    {"name": "DMR",    "damage_body": 45, "headshot_mult": 2.0, "rpm": 260, "mag_size": 20, "reload_secs": 2.6, "spread_base_deg": 0.2, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.9, "range_m": 500.0, "muzzle_velocity": 400.0, "gravity_scale": 0.35, "fire_modes": [MODE_SEMI], "burst_count": 1},
	PISTOL: {"name": "PISTOL", "damage_body": 16, "headshot_mult": 1.9, "rpm": 450, "mag_size": 15, "reload_secs": 1.6, "spread_base_deg": 0.8, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.5, "range_m": 80.0,  "muzzle_velocity": 160.0, "gravity_scale": 0.8,  "fire_modes": [MODE_SEMI], "burst_count": 1},
}

static func get_def(weapon_id: int) -> Dictionary:
	return _DEFS.get(weapon_id, _DEFS[AR])

## Per-weapon projectile lifetime in ticks: enough to cover range at muzzle speed, capped.
static func projectile_ttl_ticks(weapon_id: int) -> int:
	var d := get_def(weapon_id)
	var secs := float(d["range_m"]) / maxf(1.0, float(d["muzzle_velocity"]))
	return clampi(int(ceil(secs * 30.0)) + 4, 1, 150)

## Short display label for a fire mode (HUD indicator). Unknown -> "SEMI".
static func mode_name(mode: int) -> String:
	match mode:
		MODE_AUTO: return "AUTO"
		MODE_BURST: return "BURST"
		_: return "SEMI"

static func default_mode(weapon_id: int) -> int:
	var modes: Array = get_def(weapon_id)["fire_modes"]
	return int(modes[0]) if not modes.is_empty() else MODE_SEMI

static func mode_allowed(weapon_id: int, mode: int) -> bool:
	return mode in get_def(weapon_id)["fire_modes"]

## True if a trigger-held shot at this (mode, shot_index) is permitted.
## SEMI -> only index 0; BURST -> indices < burst_count; AUTO -> always.
static func fire_allowed(mode: int, shot_index: int, burst_count: int) -> bool:
	match mode:
		MODE_SEMI: return shot_index == 0
		MODE_BURST: return shot_index < burst_count
		_: return true

static func fire_interval(weapon_id: int) -> float:
	return 60.0 / float(get_def(weapon_id)["rpm"])

## Base weapon record with attachment multipliers applied (loadout-time; spec §"Weapon
## attachments"). `mult` is an Attachment.multipliers() dict. Returns a COPY; the registry is
## never mutated. The two passthrough fields (move_spread_mult, prone_spread_zero) are read by
## Combat.reconstruct_ray. Hit resolution uses this effective def instead of the base.
static func effective_def(weapon_id: int, mult: Dictionary) -> Dictionary:
	var d: Dictionary = get_def(weapon_id).duplicate()
	d["spread_base_deg"] = float(d["spread_base_deg"]) * float(mult.get("spread_mult", 1.0))
	d["recoil_pitch_deg"] = float(d["recoil_pitch_deg"]) * float(mult.get("recoil_mult", 1.0))
	d["range_m"] = float(d["range_m"]) * float(mult.get("range_mult", 1.0))
	d["move_spread_mult"] = float(mult.get("move_spread_mult", 1.0))
	d["prone_spread_zero"] = bool(mult.get("prone_spread_zero", false))
	return d
