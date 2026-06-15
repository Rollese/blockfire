class_name PieceCatalog
extends RefCounted
## Data-driven fortification piece types, parsed from JSON in pieces/ and validated; the
## server refuses to start on an invalid catalog. The single source of truth for piece
## geometry/health shared by server (validation, cover) and the structure store (AABB).
## Index in array order == the u8 `type` on the wire. See docs/specs/building.md.

var pieces: Array = []   # [{id:String, half:bool, health:int}]

func size() -> int:
	return pieces.size()

func is_half(type: int) -> bool:
	return bool(pieces[type]["half"])

func health_of(type: int) -> int:
	return int(pieces[type]["health"])

func name_of(type: int) -> String:
	return String(pieces[type]["id"])

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
		c.pieces.append({"id": id, "half": height == "half", "health": health})
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
