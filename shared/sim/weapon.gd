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
	if _VARIANTS.has(weapon_id):
		return _VARIANTS[weapon_id]
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

# --- Named-variant registry (data/weapons.json). Ids >= 16 so they never collide with the
# archetype enum (0..5). Loaded once at boot by server + client; tests load a fixture dict. ---
static var _VARIANTS: Dictionary = {}       # id(int) -> resolved def (fire_modes+archetype as ints)
static var _BY_ARCHETYPE: Dictionary = {}   # archetype(int) -> ordered Array[int] of variant ids

# "LMG" maps to 5 as a LITERAL on purpose: the LMG enum entry is owned by the parallel loadout
# agent (spec §4). Referencing a not-yet-existent Weapon.LMG here would create a merge collision;
# the literal 5 is the agreed value and stays correct once their `LMG = 5` enum lands.
const _ARCH := {"AR": AR, "SMG": SMG, "DMR": DMR, "RPG": RPG, "PISTOL": PISTOL, "LMG": 5}
const _MODE := {"AUTO": MODE_AUTO, "SEMI": MODE_SEMI, "BURST": MODE_BURST}
const _FLOAT_FIELDS := ["headshot_mult", "reload_secs", "spread_base_deg", "spread_bloom_deg",
	"recoil_pitch_deg", "range_m", "muzzle_velocity", "gravity_scale"]

static func load_from_dict(data: Dictionary) -> Dictionary:
	var raw = data.get("weapons", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "error": "weapons must be a non-empty array"}
	var variants := {}
	var keys := {}
	var by_arch := {}
	for w in raw:
		if not (w is Dictionary):
			return {"ok": false, "error": "each weapon must be an object"}
		var id := int(w.get("id", -1))
		if id < 16:
			return {"ok": false, "error": "weapon id must be an int >= 16 (got %d)" % id}
		if variants.has(id):
			return {"ok": false, "error": "duplicate weapon id %d" % id}
		var key := String(w.get("key", ""))
		if key == "":
			return {"ok": false, "error": "weapon %d missing key" % id}
		if keys.has(key):
			return {"ok": false, "error": "duplicate weapon key '%s'" % key}
		keys[key] = true
		var arch_s := String(w.get("archetype", ""))
		if not _ARCH.has(arch_s):
			return {"ok": false, "error": "weapon %s: unknown archetype '%s'" % [key, arch_s]}
		var modes := []
		if typeof(w.get("fire_modes", [])) != TYPE_ARRAY:
			return {"ok": false, "error": "weapon %s: fire_modes must be an array" % key}
		for m in w.get("fire_modes", []):
			if not _MODE.has(String(m)):
				return {"ok": false, "error": "weapon %s: bad fire mode '%s'" % [key, m]}
			modes.append(_MODE[String(m)])
		if modes.is_empty():
			return {"ok": false, "error": "weapon %s: fire_modes empty" % key}
		if int(w.get("damage_body", 0)) <= 0 or int(w.get("mag_size", 0)) <= 0 or int(w.get("rpm", 0)) <= 0 \
				or float(w.get("range_m", 0.0)) <= 0.0 or float(w.get("muzzle_velocity", 0.0)) <= 0.0:
			return {"ok": false, "error": "weapon %s: damage/mag/rpm/range/muzzle must be > 0" % key}
		var def := {
			"key": key, "name": String(w.get("name", key)), "archetype": int(_ARCH[arch_s]),
			"damage_body": int(w.get("damage_body", 0)), "rpm": int(w.get("rpm", 0)),
			"mag_size": int(w.get("mag_size", 0)), "reserve_ammo": int(w.get("reserve_ammo", 0)),
			"fire_modes": modes, "burst_count": int(w.get("burst_count", DEFAULT_BURST)),
			"suppression_mult": float(w.get("suppression_mult", 1.0)),
		}
		for f in _FLOAT_FIELDS:
			def[f] = float(w.get(f, 0.0))
		variants[id] = def
		var a := int(_ARCH[arch_s])
		if not by_arch.has(a):
			by_arch[a] = []
		by_arch[a].append(id)
	_VARIANTS = variants
	_BY_ARCHETYPE = by_arch
	return {"ok": true, "error": ""}

static func load_from_file(path := "res://data/weapons.json") -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return {"ok": false, "error": "cannot read %s" % path}
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "error": "root of %s is not an object" % path}
	return load_from_dict(data)

## Test-only: clear the loaded variant registry so a test starts from a known-empty state.
static func reset_registry() -> void:
	_VARIANTS = {}
	_BY_ARCHETYPE = {}

static func is_variant(id: int) -> bool:
	return _VARIANTS.has(id)

static func archetype_of(id: int) -> int:
	if _VARIANTS.has(id):
		return int(_VARIANTS[id]["archetype"])
	if _DEFS.has(id):
		return id
	return AR

static func variants_of(archetype: int) -> Array:
	return _BY_ARCHETYPE.get(archetype, [])

static func default_variant(archetype: int) -> int:
	var v: Array = _BY_ARCHETYPE.get(archetype, [])
	return int(v[0]) if not v.is_empty() else archetype

static func display_name(id: int) -> String:
	if _VARIANTS.has(id):
		return String(_VARIANTS[id]["name"])
	return String(_DEFS.get(id, _DEFS[AR]).get("name", "?"))
