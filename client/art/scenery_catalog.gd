class_name SceneryCatalog
extends RefCounted
## Loader for data/scenery_catalog.json — Broken Vector tree/rock GLB ids -> res:// paths.
## Presentation-only; map JSON references ids from this catalog.

var _items: Dictionary = {}   # id:String -> {id, category, name, path}

func has_id(scenery_id: String) -> bool:
	return _items.has(scenery_id)

func path_for(scenery_id: String) -> String:
	var item: Variant = _items.get(scenery_id, {})
	if item is Dictionary:
		return String(item.get("path", ""))
	return ""

func category_for(scenery_id: String) -> String:
	var item: Variant = _items.get(scenery_id, {})
	if item is Dictionary:
		return String(item.get("category", ""))
	return ""

func ids() -> Array:
	return _items.keys()

static func from_dict(data: Dictionary) -> Dictionary:
	var c := SceneryCatalog.new()
	var raw: Variant = data.get("items", {})
	if typeof(raw) != TYPE_DICTIONARY or raw.is_empty():
		return {"ok": false, "catalog": null, "error": "items must be a non-empty object"}
	for key in raw.keys():
		var entry: Variant = raw[key]
		if not (entry is Dictionary):
			return {"ok": false, "catalog": null, "error": "each item must be an object"}
		var id := String(entry.get("id", key))
		var path := String(entry.get("path", ""))
		if id == "" or path == "":
			return {"ok": false, "catalog": null, "error": "each item needs id + path"}
		c._items[id] = {
			"id": id,
			"category": String(entry.get("category", "")),
			"name": String(entry.get("name", id)),
			"path": path,
		}
	return {"ok": true, "catalog": c, "error": ""}

static func load_file(path: String) -> SceneryCatalog:
	if not FileAccess.file_exists(path):
		push_error("[scenery] not found: %s" % path)
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("[scenery] root is not an object: %s" % path)
		return null
	var res := from_dict(data)
	if not res["ok"]:
		push_error("[scenery] invalid %s: %s" % [path, res["error"]])
		return null
	return res["catalog"]
