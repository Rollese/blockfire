class_name Weapon
extends Object
## Data-driven hit-scan weapon registry. M2: flat damage to range, then 0.

enum { AR = 0, SMG = 1, DMR = 2 }

const _DEFS := {
	AR:  {"name": "AR",  "damage_body": 25, "headshot_mult": 2.0, "rpm": 600, "mag_size": 30, "reload_secs": 2.2, "spread_base_deg": 0.6, "spread_bloom_deg": 0.5, "recoil_pitch_deg": 0.4, "range_m": 300.0},
	SMG: {"name": "SMG", "damage_body": 18, "headshot_mult": 1.8, "rpm": 900, "mag_size": 35, "reload_secs": 2.0, "spread_base_deg": 1.0, "spread_bloom_deg": 0.6, "recoil_pitch_deg": 0.3, "range_m": 150.0},
	DMR: {"name": "DMR", "damage_body": 45, "headshot_mult": 2.0, "rpm": 260, "mag_size": 20, "reload_secs": 2.6, "spread_base_deg": 0.2, "spread_bloom_deg": 0.3, "recoil_pitch_deg": 0.9, "range_m": 500.0},
}

static func get_def(weapon_id: int) -> Dictionary:
	return _DEFS.get(weapon_id, _DEFS[AR])

static func fire_interval(weapon_id: int) -> float:
	return 60.0 / float(get_def(weapon_id)["rpm"])
