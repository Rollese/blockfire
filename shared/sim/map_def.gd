class_name MapDef
extends RefCounted
## Data-driven Conquest map: capture points + per-team home bases. Parsed from JSON in
## maps/ and validated; the server refuses to start on an invalid map. The single source
## of truth for point/base geometry shared by server and bots. See docs/specs/m3-conquest-squads.md.

## Default carriageway width (metres) for a spline road that omits `width`. Two lanes + shoulders.
const ROAD_DEFAULT_WIDTH := 8.0

var name: String = ""
var world_half: float = 1000.0
var points: Array = []   # [{id:String, pos:Vector3, radius:float, start_owner:int}]
var bases: Array = []    # [{team:int, pos:Vector3, radius:float}]
var ladders: Array = []   # [{bottom:Vector3, top:Vector3, radius:float}]
var platforms: Array = [] # [{min:Vector3, max:Vector3}]
var roads: Array = []     # cosmetic ground strips (no collision; client-rendered). TWO forms:
                          #   legacy AABB  {min:Vector3, max:Vector3}       -> flat strips, non-terrain maps only
                          #   spline (M22) {spline:PackedVector2Array, width:float} -> draped ribbon, any map
var prebuilt: Array = []  # [{type:String (piece id), cell:Vector3i}] pre-placed at server start
var buildings: Array = []  # [{prefab:String, origin_cell:Vector3i, yaw:int}]
var scenery: Array = []  # [{id, pos, yaw, scale, palette?}] cosmetic trees/rocks (client-only)
var scenery_palette: Dictionary = {}  # optional {tree:String, rock:String} colorsheet names (client-only)
var vehicle_spawns: Array = []  # [{team:int, type:String, pos:Vector3, heading:float}]
var terrain: Dictionary = {}   # {heightmap:String, sample_spacing:float, height_min:float, height_scale:float} or {} (flat)

func base_for(team: int) -> Dictionary:
	for b in bases:
		if b["team"] == team:
			return b
	return {}

static func _vec3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

## Returns {"ok": bool, "map": MapDef, "error": String}.
static func from_json_string(text: String) -> Dictionary:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false, "map": null, "error": "root is not an object"}
	return from_dict(data)

static func from_dict(data: Dictionary) -> Dictionary:
	var m := MapDef.new()
	m.name = String(data.get("name", ""))
	m.world_half = float(data.get("world_half", 1000.0))
	var raw_points = data.get("points", [])
	if typeof(raw_points) != TYPE_ARRAY or raw_points.is_empty():
		return {"ok": false, "map": null, "error": "points must be a non-empty array"}
	for pt in raw_points:
		if not (pt is Dictionary) or not pt.has("pos") or not (pt["pos"] is Array) or pt["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each point needs a 3-number pos"}
		var radius := float(pt.get("radius", 0.0))
		if radius <= 0.0:
			return {"ok": false, "map": null, "error": "point radius must be > 0"}
		var so := int(pt.get("start_owner", -1))
		if so < -1 or so > 1:
			return {"ok": false, "map": null, "error": "start_owner must be -1, 0 or 1"}
		m.points.append({"id": String(pt.get("id", "")), "pos": _vec3(pt["pos"]), "radius": radius, "start_owner": so})
	var raw_bases = data.get("bases", [])
	if typeof(raw_bases) != TYPE_ARRAY:
		return {"ok": false, "map": null, "error": "bases must be an array"}
	for b in raw_bases:
		if not (b is Dictionary) or not b.has("pos") or not (b["pos"] is Array) or b["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each base needs a 3-number pos"}
		m.bases.append({"team": int(b.get("team", 0)), "pos": _vec3(b["pos"]), "radius": float(b.get("radius", 1.0))})
	if m.base_for(0).is_empty() or m.base_for(1).is_empty():
		return {"ok": false, "map": null, "error": "need one base per team {0,1}"}
	for l in data.get("ladders", []):
		if not (l is Dictionary) or not l.has("bottom") or not l.has("top"):
			return {"ok": false, "map": null, "error": "each ladder needs bottom + top"}
		# `building` = index of the building this ladder is attached to (from map_gen); building_id defaults
		# to index+1 (the server's stamping order on a clean map) and is re-stamped authoritatively server-
		# side. 0 = unattached. Drives ladder removal when the building collapses (H1).
		var _b_idx := int(l.get("building", -1))
		m.ladders.append({"bottom": _vec3(l["bottom"]), "top": _vec3(l["top"]), "radius": float(l.get("radius", 0.6)),
			"yaw": float(l.get("yaw", 0.0)),   # render facing (rungs face this way); climb volume is yaw-agnostic
			"building_index": _b_idx, "building_id": (_b_idx + 1) if _b_idx >= 0 else 0})
	for pf in data.get("platforms", []):
		if not (pf is Dictionary) or not pf.has("min") or not pf.has("max"):
			return {"ok": false, "map": null, "error": "each platform needs min + max"}
		m.platforms.append({"min": _vec3(pf["min"]), "max": _vec3(pf["max"])})
	# Roads come in two forms and both must keep working. The legacy AABB form predates terrain and
	# renders as a FLAT strip (world_renderer skips it on terrain maps — a flat plane buries under a
	# hill). The M22 spline form drapes a real ribbon over the heightmap and is what the map editor
	# writes. Cosmetic either way: the sim never reads roads.
	for rd in data.get("roads", []):
		if not (rd is Dictionary):
			return {"ok": false, "map": null, "error": "each road must be an object"}
		if rd.has("spline"):
			if not (rd["spline"] is Array) or rd["spline"].size() < 2:
				return {"ok": false, "map": null, "error": "a spline road needs >= 2 control points"}
			var sp := PackedVector2Array()
			for cp in rd["spline"]:
				if not (cp is Array) or cp.size() != 2:
					return {"ok": false, "map": null, "error": "each road spline point needs [x, z]"}
				sp.append(Vector2(float(cp[0]), float(cp[1])))
			var w := float(rd.get("width", ROAD_DEFAULT_WIDTH))
			if w <= 0.0:
				return {"ok": false, "map": null, "error": "road width must be > 0"}
			m.roads.append({"spline": sp, "width": w})
		elif rd.has("min") and rd.has("max"):
			m.roads.append({"min": _vec3(rd["min"]), "max": _vec3(rd["max"])})
		else:
			return {"ok": false, "map": null, "error": "each road needs either min+max (AABB) or spline"}
	for pb in data.get("prebuilt", []):
		if not (pb is Dictionary) or not pb.has("type") or not pb.has("cell") or pb["cell"].size() != 3:
			return {"ok": false, "map": null, "error": "each prebuilt needs type + 3-int cell"}
		var c = pb["cell"]
		m.prebuilt.append({"type": String(pb["type"]), "cell": Vector3i(int(c[0]), int(c[1]), int(c[2]))})
	for b in data.get("buildings", []):
		if not (b is Dictionary) or not b.has("prefab") or not b.has("origin_cell") \
				or not (b["origin_cell"] is Array) or b["origin_cell"].size() != 3:
			return {"ok": false, "map": null, "error": "each building needs prefab + 3-int origin_cell"}
		var oc = b["origin_cell"]
		var byaw := int(b.get("yaw", 0))
		if byaw < 0 or byaw >= BuildGrid.YAW_STEPS:
			return {"ok": false, "map": null, "error": "building yaw out of range"}
		var bentry := {
			"prefab": String(b["prefab"]),
			"origin_cell": Vector3i(int(oc[0]), int(oc[1]), int(oc[2])),
			"yaw": byaw,
			"terrain_cutout": bool(b.get("terrain_cutout", false)),
		}
		# Optional baked world-AABB footprint (map_gen). Lets Terrain.load_for_map flatten the FULL
		# building pad (not just the origin cell) so buildings sit flush on sloped terrain — without a
		# runtime prefab-extent dependency. {min_x,max_x,min_z,max_z} in world metres.
		if b.has("footprint") and b["footprint"] is Dictionary:
			var f: Dictionary = b["footprint"]
			bentry["footprint"] = {
				"min_x": float(f.get("min_x", 0.0)), "max_x": float(f.get("max_x", 0.0)),
				"min_z": float(f.get("min_z", 0.0)), "max_z": float(f.get("max_z", 0.0)),
			}
		m.buildings.append(bentry)
	for sc in data.get("scenery", []):
		if not (sc is Dictionary) or not sc.has("id") or not sc.has("pos") \
				or not (sc["pos"] is Array) or sc["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each scenery needs id + 3-number pos"}
		var scale := float(sc.get("scale", 1.0))
		if scale <= 0.0:
			return {"ok": false, "map": null, "error": "scenery scale must be > 0"}
		var entry := {
			"id": String(sc["id"]),
			"pos": _vec3(sc["pos"]),
			"yaw": float(sc.get("yaw", 0.0)),
			"scale": scale,
		}
		if sc.has("palette"):
			entry["palette"] = String(sc["palette"])
		m.scenery.append(entry)
	var raw_palette: Variant = data.get("scenery_palette", {})
	if typeof(raw_palette) == TYPE_DICTIONARY:
		for key in raw_palette.keys():
			m.scenery_palette[String(key)] = String(raw_palette[key])
	for vs in data.get("vehicle_spawns", []):
		if not (vs is Dictionary) or not vs.has("pos") or not (vs["pos"] is Array) or vs["pos"].size() != 3:
			return {"ok": false, "map": null, "error": "each vehicle_spawn needs a 3-number pos"}
		m.vehicle_spawns.append({
			"team": int(vs.get("team", 0)),
			"type": String(vs.get("type", "transport")),
			"pos": _vec3(vs["pos"]),
			"heading": float(vs.get("heading", 0.0)),
		})
	var raw_terrain: Variant = data.get("terrain", {})
	if typeof(raw_terrain) == TYPE_DICTIONARY and not raw_terrain.is_empty():
		if not raw_terrain.has("heightmap"):
			return {"ok": false, "map": null, "error": "terrain needs a heightmap path"}
		m.terrain = {
			"heightmap": String(raw_terrain["heightmap"]),
			"sample_spacing": float(raw_terrain.get("sample_spacing", 2.0)),
			"height_min": float(raw_terrain.get("height_min", 0.0)),
			"height_scale": float(raw_terrain.get("height_scale", 0.0)),
		}
		# Client-only presentation key: the road/sidewalk SURFACE SPLATMAP painted into the terrain
		# shader (world_renderer._terrain_material). The server ignores it. Passed through only when
		# present so map.terrain.has("surface_map") stays a truthful "this map paints roads" signal.
		if raw_terrain.has("surface_map"):
			m.terrain["surface_map"] = String(raw_terrain["surface_map"])
	return {"ok": true, "map": m, "error": ""}

static func load_file(path: String) -> MapDef:
	if not FileAccess.file_exists(path):
		push_error("[map] not found: %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var res := from_json_string(text)
	if not res["ok"]:
		push_error("[map] invalid %s: %s" % [path, res["error"]])
		return null
	return res["map"]
