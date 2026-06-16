class_name MapDef
extends RefCounted
## Data-driven Conquest map: capture points + per-team home bases. Parsed from JSON in
## maps/ and validated; the server refuses to start on an invalid map. The single source
## of truth for point/base geometry shared by server and bots. See docs/specs/m3-conquest-squads.md.

var name: String = ""
var world_half: float = 1000.0
var points: Array = []   # [{id:String, pos:Vector3, radius:float, start_owner:int}]
var bases: Array = []    # [{team:int, pos:Vector3, radius:float}]
var ladders: Array = []   # [{bottom:Vector3, top:Vector3, radius:float}]
var platforms: Array = [] # [{min:Vector3, max:Vector3}]
var prebuilt: Array = []  # [{type:String (piece id), cell:Vector3i}] pre-placed at server start

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
		m.ladders.append({"bottom": _vec3(l["bottom"]), "top": _vec3(l["top"]), "radius": float(l.get("radius", 0.6))})
	for pf in data.get("platforms", []):
		if not (pf is Dictionary) or not pf.has("min") or not pf.has("max"):
			return {"ok": false, "map": null, "error": "each platform needs min + max"}
		m.platforms.append({"min": _vec3(pf["min"]), "max": _vec3(pf["max"])})
	for pb in data.get("prebuilt", []):
		if not (pb is Dictionary) or not pb.has("type") or not pb.has("cell") or pb["cell"].size() != 3:
			return {"ok": false, "map": null, "error": "each prebuilt needs type + 3-int cell"}
		var c = pb["cell"]
		m.prebuilt.append({"type": String(pb["type"]), "cell": Vector3i(int(c[0]), int(c[1]), int(c[2]))})
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
