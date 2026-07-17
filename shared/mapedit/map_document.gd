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
