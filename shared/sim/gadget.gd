class_name Gadget
extends RefCounted
## P2 gadget catalog + pure helpers. The catalog (data/gadgets.json) holds heterogeneous defs
## keyed by `kind`; the server queries it for constants and holds the live entity state itself
## (it ticks _c4/_mines/_rockets/_bags). Helpers here are pure/side-effect-free so they unit-test
## without the server. See docs/specs/combat-depth.md (P2).

# Kinds (match Loadout.GADGET_* where they overlap; RPG=2 has no Loadout gadget slot -- it's a weapon).
const KIND_C4 := 0
const KIND_MINE := 1
const KIND_RPG := 2
const KIND_HEAL := 3
const KIND_AMMO := 4
const KIND_REPAIR := 5
const KIND_BREACH := 8   # matches Loadout.GADGET_BREACH

const _KINDS := {"c4": KIND_C4, "mine": KIND_MINE, "rpg": KIND_RPG, "heal": KIND_HEAL, "ammo": KIND_AMMO, "repair": KIND_REPAIR, "breach": KIND_BREACH}

var _by_kind: Dictionary = {}   # kind:int -> def Dictionary

func def_of_kind(kind: int) -> Dictionary:
	return _by_kind.get(kind, {})

# --- pure helpers (no catalog/server state) ---

## True if `target` is within `radius` of `center` AND within the cone of half-angle `half_angle`
## about `facing` (claymore directional trigger). An omnidirectional mine passes half_angle=PI.
static func in_cone(center: Vector3, facing: Vector3, target: Vector3, radius: float, half_angle: float) -> bool:
	var to := target - center
	var d := to.length()
	if d > radius or d < 0.0001:
		return false
	return to.normalized().dot(facing.normalized()) >= cos(half_angle)

## True if a teammate at `target_pos`/`target_stance` is on the giver's aim ray within `range_m`
## (active heal/ammo give). Reuses the pawn hitbox so cover/aim matter; LOS vs structures is the
## caller's concern (it can march first). Pure over geometry.
static func give_hits(giver_eye: Vector3, aim_dir: Vector3, target_pos: Vector3, target_stance: int, range_m: float) -> bool:
	var hit: Dictionary = Hitbox.raycast_pawn(giver_eye, aim_dir.normalized(), target_pos, target_stance, range_m)
	return bool(hit["hit"]) and float(hit["t"]) <= range_m

## Pool after dispensing `amount`, floored at 0 (bag exhaustion check is `result == 0`).
static func decrement_pool(pool: int, amount: int) -> int:
	return maxi(0, pool - amount)

## Repair heat step. Returns {heat:int, cooldown_until:int, repairing:bool}. `want` = engineer is
## holding repair on a valid target this tick. Overheat at overheat_ticks -> cooldown_until lockout;
## heat decays when not repairing. Pure; the server owns the dicts.
static func repair_heat_step(heat: int, cooldown_until: int, tick: int, want: bool,
		overheat_ticks: int, cooldown_ticks: int) -> Dictionary:
	if tick < cooldown_until:
		return {"heat": 0, "cooldown_until": cooldown_until, "repairing": false}
	if not want:
		return {"heat": maxi(0, heat - 1), "cooldown_until": 0, "repairing": false}
	var h := heat + 1
	if h >= overheat_ticks:
		return {"heat": 0, "cooldown_until": tick + cooldown_ticks, "repairing": true}
	return {"heat": h, "cooldown_until": 0, "repairing": true}

# --- catalog loading (modeled on PieceCatalog) ---

static func from_json_string(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "catalog": null, "error": "root is not an object"}
	return from_dict(data)

static func from_dict(data: Dictionary) -> Dictionary:
	var c := Gadget.new()
	var raw = data.get("gadgets", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "catalog": null, "error": "gadgets must be a non-empty array"}
	var seen := {}
	for g in raw:
		if not (g is Dictionary):
			return {"ok": false, "catalog": null, "error": "each gadget must be an object"}
		var id := String(g.get("id", ""))
		if id == "" or seen.has(id):
			return {"ok": false, "catalog": null, "error": "gadget id must be non-empty and unique"}
		seen[id] = true
		var kind_str := String(g.get("kind", ""))
		if not _KINDS.has(kind_str):
			return {"ok": false, "catalog": null, "error": "unknown gadget kind '%s'" % kind_str}
		c._by_kind[_KINDS[kind_str]] = g
	return {"ok": true, "catalog": c, "error": ""}

static func load_file(path: String) -> Gadget:
	if not FileAccess.file_exists(path):
		push_error("[gadgets] not found: %s" % path)
		return null
	var res: Dictionary = from_json_string(FileAccess.get_file_as_string(path))
	if not res["ok"]:
		push_error("[gadgets] invalid %s: %s" % [path, res["error"]])
		return null
	return res["catalog"]
