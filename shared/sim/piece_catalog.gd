class_name PieceCatalog
extends RefCounted
## Data-driven fortification piece types, parsed from JSON in pieces/ and validated; the
## server refuses to start on an invalid catalog. The single source of truth for piece
## geometry/health shared by server (validation, cover) and the structure store (AABB).
## Index in array order == the u8 `type` on the wire. See docs/specs/building.md.

# Material tags (spec §"Bullet penetration"). Index-free enum-style ints; the wire never
# carries material (server-only, used in the fire path), so order is internal.
const MAT_WOOD := 0
const MAT_METAL_THIN := 1
const MAT_CONCRETE := 2
const MAT_METAL_THICK := 3

const _MATERIALS := {
	"WOOD": MAT_WOOD, "METAL_THIN": MAT_METAL_THIN,
	"CONCRETE": MAT_CONCRETE, "METAL_THICK": MAT_METAL_THICK,
}

# Damage-source bitflags (M11). damage_types is an OR of these; default = all.
const SRC_BULLET := 1
const SRC_EXPLOSIVE := 2
const SRC_MELEE := 4
const SRC_ALL := SRC_BULLET | SRC_EXPLOSIVE | SRC_MELEE
const _SRC_NAMES := {"bullet": SRC_BULLET, "explosive": SRC_EXPLOSIVE, "melee": SRC_MELEE}
const _VALID_GRIDS := [1, 2, 4, 8]

# Per-material penetration factors: {penetrable, absorption, transmit}. Non-penetrable
# materials stop the shot (the piece eats full body damage; nothing exits).
const _PEN := {
	MAT_WOOD:        {"penetrable": true,  "absorption": 0.40, "transmit": 0.60},
	MAT_METAL_THIN:  {"penetrable": true,  "absorption": 0.65, "transmit": 0.35},
	MAT_CONCRETE:    {"penetrable": false, "absorption": 1.0,  "transmit": 0.0},
	MAT_METAL_THICK: {"penetrable": false, "absorption": 1.0,  "transmit": 0.0},
}

static func is_penetrable(material: int) -> bool:
	return bool(_PEN[material]["penetrable"])

static func absorption_of(material: int) -> float:
	return float(_PEN[material]["absorption"])

static func transmit_of(material: int) -> float:
	return float(_PEN[material]["transmit"])

var pieces: Array = []   # [{id:String, half:bool, health:int, material:int}]

func size() -> int:
	return pieces.size()

func is_half(type: int) -> bool:
	return bool(pieces[type]["half"])

func health_of(type: int) -> int:
	return int(pieces[type]["health"])

func chunk_grid_of(type: int) -> int:
	return int(pieces[type]["chunk_grid"])

func is_structural(type: int) -> bool:
	return bool(pieces[type]["structural"])

## Pawns can walk through this piece's cell (e.g. a door aperture). The frame still blocks bullets/LOS
## (whole-cell ray march) until destroyed; only ground movement is allowed through.
func passable_of(type: int) -> bool:
	return bool(pieces[type].get("passable", false))

func takes_damage(type: int, source: int) -> bool:
	return (int(pieces[type]["damage_types"]) & source) != 0

func name_of(type: int) -> String:
	return String(pieces[type]["id"])

func material_of(type: int) -> int:
	return int(pieces[type]["material"])

static func from_json_string(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "catalog": null, "error": "root is not an object"}
	return from_dict(data)

static func from_dict(data: Dictionary) -> Dictionary:
	var c := PieceCatalog.new()
	var raw = data.get("pieces", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "catalog": null, "error": "pieces must be a non-empty array"}
	var seen := {}
	for p in raw:
		if not (p is Dictionary):
			return {"ok": false, "catalog": null, "error": "each piece must be an object"}
		var id := String(p.get("id", ""))
		if id == "" or seen.has(id):
			return {"ok": false, "catalog": null, "error": "piece id must be non-empty and unique"}
		seen[id] = true
		var height := String(p.get("height", ""))
		if height != "half" and height != "full":
			return {"ok": false, "catalog": null, "error": "height must be 'half' or 'full'"}
		var health := int(p.get("health", 0))
		if health <= 0:
			return {"ok": false, "catalog": null, "error": "health must be > 0"}
		if String(p.get("blocks", "both")) != "both":
			return {"ok": false, "catalog": null, "error": "blocks must be 'both' (v1)"}
		var mat_str := String(p.get("material", "CONCRETE"))
		if not _MATERIALS.has(mat_str):
			return {"ok": false, "catalog": null, "error": "unknown material '%s'" % mat_str}
		var grid := int(p.get("chunk_grid", 1))
		if not _VALID_GRIDS.has(grid):
			return {"ok": false, "catalog": null, "error": "chunk_grid must be one of 1,2,4,8"}
		var dmg := SRC_ALL
		if p.has("damage"):
			var raw_d = p["damage"]
			if typeof(raw_d) != TYPE_ARRAY:
				return {"ok": false, "catalog": null, "error": "damage must be an array"}
			dmg = 0
			for s in raw_d:
				var key := String(s)
				if not _SRC_NAMES.has(key):
					return {"ok": false, "catalog": null, "error": "unknown damage source '%s'" % key}
				dmg |= _SRC_NAMES[key]
		c.pieces.append({"id": id, "half": height == "half", "health": health,
			"material": _MATERIALS[mat_str], "chunk_grid": grid,
			"structural": bool(p.get("structural", false)), "damage_types": dmg,
			"passable": bool(p.get("passable", false))})
	return {"ok": true, "catalog": c, "error": ""}

static func load_file(path: String) -> PieceCatalog:
	if not FileAccess.file_exists(path):
		push_error("[pieces] not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var res := from_json_string(text)
	if not res["ok"]:
		push_error("[pieces] invalid %s: %s" % [path, res["error"]])
		return null
	return res["catalog"]
