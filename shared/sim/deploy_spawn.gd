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
# Ref spaces (u16 wire, DEPLOY_REQUEST). Pawn ids are MONOTONIC and never reused across
# disconnects, so on a persistent server they exceed 128 — the old bases (200/400/600)
# aliased a squadmate ref into vehicle space after ~200 cumulative joins. The squadmate
# span now covers ids 1..MAX_SQUADMATE_ID (~39k joins); enumerate() skips anything above
# rather than emit an aliased ref. Space ordering (squadmate < vehicle < FOB) is load-
# bearing: is_valid/resolve dispatch on ordered >= checks.
const SQUADMATE_BASE := 1000    # + pawn_id -> 1001..39999
const VEHICLE_BASE := 40000     # + slot (vid - Vehicle.ID_BASE) -> 40000..49999
const FOB_BASE := 50000         # + squad_id -> 50000..65535 (top of u16)
const MAX_SQUADMATE_ID := VEHICLE_BASE - SQUADMATE_BASE - 1

static func _mate_ok(m: Dictionary, team: int) -> bool:
	return int(m.get("team", -1)) == team and bool(m.get("alive", false)) and not bool(m.get("downed", false))

static func _veh_ok(v: Dictionary, team: int) -> bool:
	return int(v.get("team", -1)) == team and int(v.get("free_seats", 0)) > 0

static func _fob_ok(f: Dictionary) -> bool:
	return bool(f.get("enabled", false))

## Find the candidate dict whose `key` equals `val`, or {} if none.
static func _by(arr: Array, key: String, val: int) -> Dictionary:
	for e in arr:
		if int(e.get(key, -2147483648)) == val:
			return e
	return {}

static func enumerate(team: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = [], fobs: Array = []) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team and not conquest.point_contested_by_enemy(team, i):
			refs.append(i + 1)
	for m in squadmates:
		if _mate_ok(m, team) and int(m["id"]) <= MAX_SQUADMATE_ID:
			refs.append(SQUADMATE_BASE + int(m["id"]))
	for v in vehicles:
		if _veh_ok(v, team):
			refs.append(VEHICLE_BASE + int(v["slot"]))
	for f in fobs:
		if _fob_ok(f):
			refs.append(FOB_BASE + int(f["squad"]))
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = [], fobs: Array = []) -> bool:
	if ref >= FOB_BASE:
		var f := _by(fobs, "squad", ref - FOB_BASE)
		return not f.is_empty() and _fob_ok(f)
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
	# Owned and not contested by enemies on the point (BattleBit: no spawning on a contested point).
	return int(conquest.points[idx]["owner"]) == team and not conquest.point_contested_by_enemy(team, idx)

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState, squadmates: Array = [], vehicles: Array = [], fobs: Array = []) -> Vector3:
	var src := Vector3.ZERO
	if ref >= FOB_BASE:
		src = _by(fobs, "squad", ref - FOB_BASE).get("pos", Vector3.ZERO)
	elif ref >= VEHICLE_BASE:
		src = _by(vehicles, "slot", ref - VEHICLE_BASE).get("pos", Vector3.ZERO)
	elif ref >= SQUADMATE_BASE:
		src = _by(squadmates, "id", ref - SQUADMATE_BASE).get("pos", Vector3.ZERO)
	elif ref == 0:
		var base: Dictionary = map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
