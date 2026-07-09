class_name Weapon
extends Object
## Data-driven hit-scan weapon registry. M2: flat damage to range, then 0.

enum { AR = 0, SMG = 1, DMR = 2, RPG = 3, PISTOL = 4 }

const MODE_AUTO := 0
const MODE_SEMI := 1
const MODE_BURST := 2
const DEFAULT_BURST := 3

const _DEFS := {
	# muzzle_velocity is BattleBit-realistic (2026-07-03): the old 160-400 m/s placeholders forced a
	# ~1 m lead on a target strafing at 40 m — "aim dead-on a mover, whiff" even with lag comp. Real
	# rifle rounds are ~750-850 m/s (near-hitscan at close-mid range); gravity_scale still gives drop.
	# reserve_ammo: spare-bullet pool separate from the loaded mag (reserve-ammo economy, M17). Flat
	# pool, no partial-mag discard on reload — a reload moves min(mag_size - mag, reserve) into the mag.
	# Sized ~6 spare mags for primaries, marksman a touch more, pistol fewer (BattleBit-default).
	AR:     {"name": "AR",     "damage_body": 25, "headshot_mult": 2.0, "rpm": 600, "mag_size": 30, "reserve_ammo": 180, "reload_secs": 2.2, "spread_base_deg": 0.6, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.4, "range_m": 300.0, "muzzle_velocity": 750.0, "gravity_scale": 0.5,  "fire_modes": [MODE_AUTO, MODE_SEMI, MODE_BURST], "burst_count": 3},
	SMG:    {"name": "SMG",    "damage_body": 18, "headshot_mult": 1.8, "rpm": 900, "mag_size": 35, "reserve_ammo": 210, "reload_secs": 2.0, "spread_base_deg": 1.0, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.3, "range_m": 150.0, "muzzle_velocity": 420.0, "gravity_scale": 0.7,  "fire_modes": [MODE_AUTO, MODE_SEMI], "burst_count": 3},
	DMR:    {"name": "DMR",    "damage_body": 45, "headshot_mult": 2.0, "rpm": 260, "mag_size": 20, "reserve_ammo": 140, "reload_secs": 2.6, "spread_base_deg": 0.2, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.9, "range_m": 500.0, "muzzle_velocity": 850.0, "gravity_scale": 0.35, "fire_modes": [MODE_SEMI], "burst_count": 1},
	PISTOL: {"name": "PISTOL", "damage_body": 16, "headshot_mult": 1.9, "rpm": 450, "mag_size": 15, "reserve_ammo": 60,  "reload_secs": 1.6, "spread_base_deg": 0.8, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.5, "range_m": 80.0,  "muzzle_velocity": 380.0, "gravity_scale": 0.8,  "fire_modes": [MODE_SEMI], "burst_count": 1},
}

## Spare-bullet reserve pool for a hit-scan weapon (0 for weapons without a mag, e.g. RPG). Falls
## back to the AR default for unknown ids, matching get_def.
static func reserve_ammo(weapon_id: int) -> int:
	return int(get_def(weapon_id).get("reserve_ammo", 0))

## Reload transfer (reserve-ammo economy, M17): move as many rounds as the reserve allows into the
## mag — no partial-mag discard. `reserve < 0` means "unlimited" (legacy record with no reserve
## tracked) → top the mag to full and leave reserve as-is. Returns [new_mag, new_reserve]. Shared by
## the server's authoritative reload-complete and the client WeaponPredictor so they never drift.
static func reload_fill(mag: int, mag_size: int, reserve: int) -> Array:
	if reserve < 0:
		return [mag_size, reserve]
	var take: int = mini(mag_size - mag, reserve)
	return [mag + take, reserve - take]

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
