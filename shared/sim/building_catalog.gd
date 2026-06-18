class_name BuildingCatalog
extends RefCounted
## Pure loader/validator for buildings/*.json prefabs. A prefab is a name + a list of pieces,
## each {type:String, offset:Vector3i (cells from origin), yaw:int (0..YAW_STEPS-1), structural?:bool}.
## Validated against a PieceCatalog (types must exist). No engine deps beyond JSON/FileAccess.

## Returns {ok:bool, prefab:{name, pieces:[{type:int, offset:Vector3i, yaw:int, structural:bool}]}, error:String}.
static func from_dict(data: Dictionary, catalog: PieceCatalog) -> Dictionary:
	var name := String(data.get("name", ""))
	if name == "":
		return {"ok": false, "prefab": null, "error": "prefab needs a name"}
	var raw = data.get("pieces", [])
	if typeof(raw) != TYPE_ARRAY or raw.is_empty():
		return {"ok": false, "prefab": null, "error": "pieces must be a non-empty array"}
	var out: Array = []
	for p in raw:
		if not (p is Dictionary) or not p.has("type") or not p.has("offset"):
			return {"ok": false, "prefab": null, "error": "each piece needs type + offset"}
		var ti := _index_of(catalog, String(p["type"]))
		if ti < 0:
			return {"ok": false, "prefab": null, "error": "unknown piece type '%s'" % p["type"]}
		var off = p["offset"]
		if not (off is Array) or off.size() != 3:
			return {"ok": false, "prefab": null, "error": "offset must be 3 ints"}
		var yaw := int(p.get("yaw", 0))
		if yaw < 0 or yaw >= BuildGrid.YAW_STEPS:
			return {"ok": false, "prefab": null, "error": "yaw out of range"}
		out.append({
			"type": ti,
			"offset": Vector3i(int(off[0]), int(off[1]), int(off[2])),
			"yaw": yaw,
			"structural": bool(p.get("structural", catalog.is_structural(ti))),
		})
	return {"ok": true, "prefab": {"name": name, "pieces": out}, "error": ""}

static func from_json_string(text: String, catalog: PieceCatalog) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "prefab": null, "error": "root is not an object"}
	return from_dict(data, catalog)

static func load_file(path: String, catalog: PieceCatalog) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "prefab": null, "error": "not found: %s" % path}
	return from_json_string(FileAccess.get_file_as_string(path), catalog)

static func _index_of(catalog: PieceCatalog, id: String) -> int:
	for i in catalog.size():
		if catalog.name_of(i) == id:
			return i
	return -1
