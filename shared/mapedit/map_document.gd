class_name MapDocument
extends RefCounted
## The editable in-memory map model for the M22 editor. Load -> mutate -> save, round-tripping
## maps/<name>.json + its heightmap.
##
## WHY NOT MapDef: MapDef is the RUNTIME's validated, read-only view — it rejects a map that is not
## yet complete and drops keys it does not model. The editor must hold a map MID-EDIT (no points
## placed yet is a normal authoring state, not an error) and must preserve keys it does not
## understand, so saving never silently destroys data a future milestone added. Hence a separate,
## permissive model. MapValidator — not the parser — is what tells the owner about problems.
##
## Heights are stored NORMALISED 0..1 (as they sit in the image), with height_min/height_scale kept
## alongside; denormalisation to metres stays in terrain.gd.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md §4.

const HeightmapIO := preload("res://shared/mapedit/heightmap_io.gd")

var map_name: String = ""
var world_half: float = 170.0
var source_path: String = ""        # res://maps/<name>.json — where save() writes back
var base_dir: String = ""           # res://maps — heightmap paths are relative to this

# Terrain
var heights: PackedFloat32Array = PackedFloat32Array()   # normalised 0..1, row-major zi*cols+xi
var cols: int = 0
var rows: int = 0
var sample_spacing: float = 2.0
var height_min: float = 0.0
var height_scale: float = 0.0
var heightmap_rel: String = ""      # e.g. "heightmaps/conquest_town.exr"
var surface_map_rel: String = ""    # legacy splatmap, passed through untouched

# Content
var buildings: Array = []
var points: Array = []
var bases: Array = []
var roads: Array = []
var scenery: Array = []
var ladders: Array = []
var platforms: Array = []
var prebuilt: Array = []
var vehicle_spawns: Array = []
var scenery_palette: Dictionary = {}
var extra: Dictionary = {}          # any top-level key this model does not know — preserved verbatim

## Keys this model owns. Anything else in the JSON lands in `extra` and is written back on save.
const KNOWN_KEYS := ["name", "world_half", "terrain", "buildings", "points", "bases", "roads",
	"scenery", "ladders", "platforms", "prebuilt", "vehicle_spawns", "scenery_palette"]

static func load_from(path: String) -> MapDocument:
	if not FileAccess.file_exists(path):
		push_error("[map_document] not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("[map_document] %s is not a JSON object" % path)
		return null
	var doc := from_dict(data, path)
	return doc

static func from_dict(data: Dictionary, path: String) -> MapDocument:
	var d := MapDocument.new()
	d.source_path = path
	d.base_dir = path.get_base_dir() if path != "" else ""
	d.map_name = String(data.get("name", ""))
	d.world_half = float(data.get("world_half", 170.0))
	d.buildings = _dup(data.get("buildings", []))
	d.roads = _dup(data.get("roads", []))
	d.scenery = _dup(data.get("scenery", []))
	d.ladders = _dup(data.get("ladders", []))
	d.platforms = _dup(data.get("platforms", []))
	d.prebuilt = _dup(data.get("prebuilt", []))
	d.vehicle_spawns = _dup(data.get("vehicle_spawns", []))
	d.scenery_palette = (data.get("scenery_palette", {}) as Dictionary).duplicate(true)
	# Points/bases keep Vector3 positions in-model so the editor can move them directly.
	for p in data.get("points", []):
		d.points.append({"id": String(p.get("id", "")), "pos": _vec3(p["pos"]),
			"radius": float(p.get("radius", 15.0)), "start_owner": int(p.get("start_owner", -1))})
	for b in data.get("bases", []):
		d.bases.append({"team": int(b.get("team", 0)), "pos": _vec3(b["pos"]),
			"radius": float(b.get("radius", 20.0))})
	var t: Dictionary = data.get("terrain", {})
	if not t.is_empty():
		d.heightmap_rel = String(t.get("heightmap", ""))
		d.sample_spacing = float(t.get("sample_spacing", 2.0))
		d.height_min = float(t.get("height_min", 0.0))
		d.height_scale = float(t.get("height_scale", 0.0))
		d.surface_map_rel = String(t.get("surface_map", ""))
		if d.base_dir != "" and d.heightmap_rel != "":
			var img := Image.new()
			var hp := d.base_dir.path_join(d.heightmap_rel)
			if img.load(hp) == OK:
				d.cols = img.get_width()
				d.rows = img.get_height()
				d.heights = HeightmapIO.image_to_norm(img)
			else:
				push_error("[map_document] failed to load heightmap %s" % hp)
	for k in data.keys():
		if not KNOWN_KEYS.has(String(k)):
			d.extra[k] = data[k]
	return d

static func _dup(a) -> Array:
	return (a as Array).duplicate(true) if a is Array else []

static func _vec3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

## World position of terrain sample (0,0) — matches TerrainGrid.origin_x/origin_z.
func origin_xz() -> Vector2:
	return Vector2(-world_half, -world_half)

## Serialise back to the maps/*.json shape. Vector3s become [x,y,z] arrays; unknown keys are written
## back verbatim. Key order is fixed so a load->save round trip is byte-stable (a churning diff would
## make every map edit unreviewable).
func to_dict() -> Dictionary:
	var out := {}
	out["name"] = map_name
	out["world_half"] = world_half
	if not roads.is_empty():
		var rl := []
		for r in roads:
			if r.has("spline"):
				var pts := []
				# `spline` may be a PackedVector2Array (in-editor mutation) or a plain Array of
				# [x, z] pairs (raw pass-through from from_dict's JSON dup) — handle both. NOTE:
				# `raw_array as PackedVector2Array` silently zeroes every element instead of
				# erroring, so it must never be used here.
				for p in (r["spline"] as Array):
					if p is Vector2:
						pts.append([p.x, p.y])
					else:
						var a: Array = p
						pts.append([float(a[0]), float(a[1])])
				rl.append({"spline": pts, "width": float(r.get("width", 8.0))})
			else:
				rl.append({"min": _arr3(r["min"]), "max": _arr3(r["max"])})
		out["roads"] = rl
	if not buildings.is_empty():
		out["buildings"] = _normalize_numbers(buildings)
	if not ladders.is_empty():
		out["ladders"] = _normalize_numbers(ladders)
	if not platforms.is_empty():
		out["platforms"] = _normalize_numbers(platforms)
	if not prebuilt.is_empty():
		out["prebuilt"] = _normalize_numbers(prebuilt)
	var pl := []
	for p in points:
		pl.append({"id": p["id"], "pos": _arr3(p["pos"]), "radius": p["radius"], "start_owner": p["start_owner"]})
	out["points"] = pl
	var bl := []
	for b in bases:
		bl.append({"team": b["team"], "pos": _arr3(b["pos"]), "radius": b["radius"]})
	out["bases"] = bl
	out["vehicle_spawns"] = _normalize_numbers(vehicle_spawns)
	if cols > 0 and rows > 0 and heightmap_rel != "":
		var t := {"heightmap": heightmap_rel, "sample_spacing": sample_spacing,
			"height_min": height_min, "height_scale": height_scale}
		if surface_map_rel != "":
			t["surface_map"] = surface_map_rel
		out["terrain"] = t
	if not scenery.is_empty():
		out["scenery"] = _normalize_numbers(scenery)
	if not scenery_palette.is_empty():
		out["scenery_palette"] = scenery_palette.duplicate(true)
	for k in extra.keys():
		out[k] = _normalize_numbers(extra[k])
	return out

## Godot's JSON parser always returns numbers as float (there is no int in the JSON spec), but
## GDScript dictionary/array literals keep whatever int/float type they were written with. Several
## fields above (buildings, ladders, platforms, prebuilt, vehicle_spawns, scenery, extra) are raw
## pass-through from from_dict with no per-field int()/float() coercion, so a document built directly
## in-memory (ints) and the same document reloaded from its own saved JSON (floats) would otherwise
## serialise differently — breaking the load->save->load->save byte-stability bar. Normalise ints to
## float here so first-save and post-reload-save agree regardless of where the data originated.
static func _normalize_numbers(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary).keys():
			out[k] = _normalize_numbers(v[k])
		return out
	elif v is Array:
		var out := []
		for e in (v as Array):
			out.append(_normalize_numbers(e))
		return out
	elif typeof(v) == TYPE_INT:
		return float(v)
	# Editor tools store origin_cell as Vector3i and prop pos as Vector3 (see editor_dock.gd's
	# doc_place_building / doc_place_prop). JSON.stringify would emit those as "(x, y, z)" STRINGS,
	# which map_def.gd rejects (origin_cell/pos must each be a 3-element Array). Flatten Godot vector
	# types to plain float arrays so editor-authored maps load in the game.
	elif typeof(v) == TYPE_VECTOR3 or typeof(v) == TYPE_VECTOR3I:
		return [float(v.x), float(v.y), float(v.z)]
	elif typeof(v) == TYPE_VECTOR2 or typeof(v) == TYPE_VECTOR2I:
		return [float(v.x), float(v.y)]
	return v

## Write the JSON + the heightmap. Migrates the heightmap to EXR: PNG cannot carry the precision
## (see heightmap_io.gd), so any map saved from the editor gets an .exr and its terrain block is
## repointed at it. Returns an Error code.
func save() -> int:
	if source_path == "":
		push_error("[map_document] save() with no source_path")
		return ERR_UNCONFIGURED
	if base_dir == "":
		base_dir = source_path.get_base_dir()
	if cols > 0 and rows > 0:
		if heightmap_rel == "" :
			heightmap_rel = "heightmaps/%s.exr" % source_path.get_file().get_basename()
		elif heightmap_rel.get_extension().to_lower() == "png":
			heightmap_rel = "%s.exr" % heightmap_rel.get_basename()
		var herr := HeightmapIO.save_exr_norm(heights, cols, rows, base_dir.path_join(heightmap_rel))
		if herr != OK:
			push_error("[map_document] heightmap save failed (%d)" % herr)
			return herr
	var f := FileAccess.open(source_path, FileAccess.WRITE)
	if f == null:
		push_error("[map_document] cannot write %s" % source_path)
		return ERR_CANT_CREATE
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	return OK

static func _arr3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]
