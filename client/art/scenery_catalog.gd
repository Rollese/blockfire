class_name SceneryCatalog
extends RefCounted
## Loader for data/scenery_catalog.json — Broken Vector tree/rock GLB ids, colorsheet palettes.
## Presentation-only; map JSON references ids from this catalog and optional map-wide palette names.

var _items: Dictionary = {}      # id:String -> {id, category, name, path}
var _palettes: Dictionary = {}   # category:String -> {palette_name: res_path}
var _defaults: Dictionary = {}   # category:String -> default palette name

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

func default_palette_for(category: String) -> String:
	return String(_defaults.get(category, ""))

func has_palette(category: String, palette_name: String) -> bool:
	var group: Variant = _palettes.get(category, {})
	return group is Dictionary and group.has(palette_name)

func palette_path_for(category: String, palette_name: String) -> String:
	var group: Variant = _palettes.get(category, {})
	if group is Dictionary and group.has(palette_name):
		return String(group[palette_name])
	return ""

func ids() -> Array:
	return _items.keys()

static func from_dict(data: Dictionary) -> Dictionary:
	var c := SceneryCatalog.new()
	var raw_defaults: Variant = data.get("defaults", {})
	if typeof(raw_defaults) == TYPE_DICTIONARY:
		for key in raw_defaults.keys():
			c._defaults[String(key)] = String(raw_defaults[key])
	var raw_palettes: Variant = data.get("palettes", {})
	if typeof(raw_palettes) == TYPE_DICTIONARY:
		for category in raw_palettes.keys():
			var group: Variant = raw_palettes[category]
			if not (group is Dictionary):
				return {"ok": false, "catalog": null, "error": "each palette group must be an object"}
			var mapped: Dictionary = {}
			for palette_name in group.keys():
				mapped[String(palette_name)] = String(group[palette_name])
			c._palettes[String(category)] = mapped
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
