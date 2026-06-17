class_name DeploySpawn
extends Object
## Pure spawn-ref resolution for human deploy. ref 0 = team base/HQ; ref i>=1 = capture point
## index (i-1), valid only if owned by the team.
## SQUADMATE_BASE + pawn_id  = spawn on that squadmate (keyed by the mate's STABLE pawn id, 1..128).
## VEHICLE_BASE  + slot      = spawn on that friendly vehicle (keyed by the vehicle's STABLE slot).
## Refs are keyed by entity identity, NOT array position: the client and server build their
## candidate arrays in different order/membership, so a positional index would alias to the wrong
## entity across the wire. Server validates+places; client enumerates for the deploy screen.
## Position uses the same jitter as SpawnSelect to avoid stacking.

const JITTER := 6.0
const SQUADMATE_BASE := 200   # + pawn_id (1..128) -> 201..328
const VEHICLE_BASE := 400     # + slot (vid - Vehicle.ID_BASE); kept above max squadmate ref (328)

static func _mate_ok(m: Dictionary, team: int) -> bool:
	return int(m.get("team", -1)) == team and bool(m.get("alive", false)) and not bool(m.get("downed", false))

static func _veh_ok(v: Dictionary, team: int) -> bool:
	return int(v.get("team", -1)) == team and int(v.get("free_seats", 0)) > 0

## Find the candidate dict whose `key` equals `val`, or {} if none.
static func _by(arr: Array, key: String, val: int) -> Dictionary:
	for e in arr:
		if int(e.get(key, -2147483648)) == val:
			return e
	return {}

static func enumerate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team:
			refs.append(i + 1)
	for m in squadmates:
		if _mate_ok(m, team):
			refs.append(SQUADMATE_BASE + int(m["id"]))
	for v in vehicles:
		if _veh_ok(v, team):
			refs.append(VEHICLE_BASE + int(v["slot"]))
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> bool:
	if ref >= VEHICLE_BASE:
		var v := _by(vehicles, "slot", ref - VEHICLE_BASE)
		return not v.is_empty() and _veh_ok(v, team)
	if ref >= SQUADMATE_BASE:
		var m := _by(squadmates, "id", ref - SQUADMATE_BASE)
		return not m.is_empty() and _mate_ok(m, team)
	if ref == 0:
		return not map.base_for(team).is_empty()
	var idx := ref - 1
	if idx < 0 or idx >= conquest.points.size():
		return false
	return int(conquest.points[idx]["owner"]) == team

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = []) -> Vector3:
	var src := Vector3.ZERO
	if ref >= VEHICLE_BASE:
		src = _by(vehicles, "slot", ref - VEHICLE_BASE).get("pos", Vector3.ZERO)
	elif ref >= SQUADMATE_BASE:
		src = _by(squadmates, "id", ref - SQUADMATE_BASE).get("pos", Vector3.ZERO)
	elif ref == 0:
		var base: Dictionary = map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
