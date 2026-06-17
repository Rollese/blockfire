class_name DeploySpawn
extends Object
## Pure spawn-ref resolution for human deploy. ref 0 = team base/HQ; ref i>=1 = capture point
## index (i-1), valid only if owned by the team. SQUADMATE_BASE+i = squadmate at index i;
## VEHICLE_BASE+i = friendly vehicle at index i. Server validates+places; client enumerates for
## the deploy screen. Position uses the same jitter as SpawnSelect to avoid stacking.

const JITTER := 6.0
const SQUADMATE_BASE := 200
const VEHICLE_BASE := 220

static func _mate_ok(m: Dictionary, team: int) -> bool:
	return int(m.get("team", -1)) == team and bool(m.get("alive", false)) and not bool(m.get("downed", false))

static func _veh_ok(v: Dictionary, team: int) -> bool:
	return int(v.get("team", -1)) == team and int(v.get("free_seats", 0)) > 0

static func enumerate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team:
			refs.append(i + 1)
	for i in squadmates.size():
		if _mate_ok(squadmates[i], team):
			refs.append(SQUADMATE_BASE + i)
	for i in vehicles.size():
		if _veh_ok(vehicles[i], team):
			refs.append(VEHICLE_BASE + i)
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> bool:
	if ref >= VEHICLE_BASE:
		var vi := ref - VEHICLE_BASE
		return vi >= 0 and vi < vehicles.size() and _veh_ok(vehicles[vi], team)
	if ref >= SQUADMATE_BASE:
		var si := ref - SQUADMATE_BASE
		return si >= 0 and si < squadmates.size() and _mate_ok(squadmates[si], team)
	if ref == 0:
		return not map.base_for(team).is_empty()
	var idx := ref - 1
	if idx < 0 or idx >= conquest.points.size():
		return false
	return int(conquest.points[idx]["owner"]) == team

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Vector3:
	var src := Vector3.ZERO
	if ref >= VEHICLE_BASE:
		src = vehicles[ref - VEHICLE_BASE]["pos"]
	elif ref >= SQUADMATE_BASE:
		src = squadmates[ref - SQUADMATE_BASE]["pos"]
	elif ref == 0:
		var base: Dictionary = map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
