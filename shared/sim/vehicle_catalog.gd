class_name VehicleCatalog
extends RefCounted
## Data-driven vehicle defs (data/vehicles.json), modeled on PieceCatalog/Gadget loaders.
## Indexed by type (array order). Holds raw def dicts; callers read keys or build a Vehicle.

var _defs: Array = []   # type:int -> def Dictionary

func size() -> int:
	return _defs.size()

func def_of(type: int) -> Dictionary:
	return _defs[type] if type >= 0 and type < _defs.size() else {}

func index_of(name: String) -> int:
	for i in _defs.size():
		if String(_defs[i].get("name", "")) == name:
			return i
	return -1

static func from_dict(data: Dictionary) -> Dictionary:
	var c := VehicleCatalog.new()
	var raw = data.get("vehicles", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "catalog": null, "error": "vehicles must be a non-empty array"}
	var seen := {}
	for v in raw:
		if not (v is Dictionary):
			return {"ok": false, "catalog": null, "error": "each vehicle must be an object"}
		var nm := String(v.get("name", ""))
		if nm == "" or seen.has(nm):
			return {"ok": false, "catalog": null, "error": "vehicle name must be non-empty and unique"}
		seen[nm] = true
		c._defs.append(v)
	return {"ok": true, "catalog": c, "error": ""}

static func load_file(path: String) -> VehicleCatalog:
	if not FileAccess.file_exists(path):
		push_error("[vehicles] not found: %s" % path); return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("[vehicles] root is not an object: %s" % path); return null
	var res := from_dict(data)
	if not res["ok"]:
		push_error("[vehicles] invalid %s: %s" % [path, res["error"]]); return null
	return res["catalog"]
