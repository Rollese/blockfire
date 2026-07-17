class_name MapValidator
extends RefCounted
## Pure map-authoring checks for the M22 editor. Ports the intent of the Python validator in
## tools/map_gen.py (aabb/overlap + building-on-road) to GDScript so the editor can surface problems
## AS the owner places things instead of at generate-time. Returns human-readable strings straight
## into the dock's validation panel — this is owner-facing text, not a log.
##
## Operates on a plain Dictionary (the MapDocument's data), NOT a MapDef, so it can run on a
## half-authored map that would not yet pass MapDef's parse.
## See docs/superpowers/specs/2026-07-16-map-editor-design.md §4.

const RoadBuilder := preload("res://shared/mapedit/road_builder.gd")

## Buildings sharing an edge are terraced housing, not a bug. Only flag a REAL area intersection.
const OVERLAP_EPSILON := 0.01

static func check(doc: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var world_half := float(doc.get("world_half", 0.0))
	var buildings: Array = doc.get("buildings", [])
	# 1. Building/building overlap.
	for i in buildings.size():
		var fa := _footprint(buildings[i])
		if fa.is_empty():
			continue
		if not _in_bounds(fa, world_half):
			errs.append("building '%s' (#%d) is out of bounds (world_half %.1f)" % [_name_of(buildings[i]), i, world_half])
		for j in range(i + 1, buildings.size()):
			var fb := _footprint(buildings[j])
			if fb.is_empty():
				continue
			if _overlap(fa, fb):
				errs.append("building '%s' (#%d) and '%s' (#%d) overlap" % [
					_name_of(buildings[i]), i, _name_of(buildings[j]), j])
	# 2. Building on a road.
	for i in buildings.size():
		var fa := _footprint(buildings[i])
		if fa.is_empty():
			continue
		for r in doc.get("roads", []):
			if _building_on_road(fa, r):
				errs.append("building '%s' (#%d) sits on a road" % [_name_of(buildings[i]), i])
				break
	# 3. Capture points.
	var points: Array = doc.get("points", [])
	if points.is_empty():
		errs.append("map has no capture points")
	for p in points:
		var pid := String(p.get("id", "?"))
		var pos: Vector3 = p.get("pos", Vector3.ZERO)
		if float(p.get("radius", 0.0)) <= 0.0:
			errs.append("capture point '%s' has radius <= 0" % pid)
		if absf(pos.x) > world_half or absf(pos.z) > world_half:
			errs.append("capture point '%s' is outside the map bounds" % pid)
	# 4. Bases: exactly one per team.
	var seen := {}
	for b in doc.get("bases", []):
		seen[int(b.get("team", -1))] = true
		var bpos: Vector3 = b.get("pos", Vector3.ZERO)
		if absf(bpos.x) > world_half or absf(bpos.z) > world_half:
			errs.append("team %d base is outside the map bounds" % int(b.get("team", -1)))
	for team in [0, 1]:
		if not seen.has(team):
			errs.append("map is missing team %d's base" % team)
	return errs

static func _name_of(b: Dictionary) -> String:
	return String(b.get("prefab", "?"))

## World AABB of a building: the baked `footprint` when present (map_gen bakes it), else the origin
## cell alone. Returns {} when neither is available.
static func _footprint(b: Dictionary) -> Dictionary:
	if b.has("footprint") and b["footprint"] is Dictionary:
		var f: Dictionary = b["footprint"]
		return {"min_x": float(f["min_x"]), "max_x": float(f["max_x"]),
			"min_z": float(f["min_z"]), "max_z": float(f["max_z"])}
	if b.has("origin_cell"):
		var mn := BuildGrid.cell_min(b["origin_cell"] as Vector3i)
		return {"min_x": mn.x, "max_x": mn.x + BuildGrid.CELL_SIZE,
			"min_z": mn.z, "max_z": mn.z + BuildGrid.CELL_SIZE}
	return {}

static func _in_bounds(f: Dictionary, world_half: float) -> bool:
	return f["min_x"] >= -world_half and f["max_x"] <= world_half \
		and f["min_z"] >= -world_half and f["max_z"] <= world_half

static func _overlap(a: Dictionary, b: Dictionary) -> bool:
	return a["min_x"] < b["max_x"] - OVERLAP_EPSILON and b["min_x"] < a["max_x"] - OVERLAP_EPSILON \
		and a["min_z"] < b["max_z"] - OVERLAP_EPSILON and b["min_z"] < a["max_z"] - OVERLAP_EPSILON

## A building conflicts with a road when their footprints intersect. AABB roads compare directly;
## spline roads are tested against the swept corridor (any resampled centre within width/2 + the
## building's half-diagonal reach).
static func _building_on_road(f: Dictionary, r: Dictionary) -> bool:
	if r.has("min") and r.has("max"):
		var rmin: Vector3 = r["min"]
		var rmax: Vector3 = r["max"]
		return _overlap(f, {"min_x": minf(rmin.x, rmax.x), "max_x": maxf(rmin.x, rmax.x),
			"min_z": minf(rmin.z, rmax.z), "max_z": maxf(rmin.z, rmax.z)})
	if r.has("spline"):
		var half := float(r.get("width", 8.0)) * 0.5
		var pts := RoadBuilder.resample(r["spline"] as PackedVector2Array, RoadBuilder.RESAMPLE_STEP)
		for p in pts:
			# Closest point on the building AABB to this road sample.
			var cx := clampf(p.x, f["min_x"], f["max_x"])
			var cz := clampf(p.y, f["min_z"], f["max_z"])
			if Vector2(cx, cz).distance_to(p) < half - OVERLAP_EPSILON:
				return true
	return false
