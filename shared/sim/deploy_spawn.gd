class_name DeploySpawn
extends Object
## Pure spawn-ref resolution for human deploy. ref 0 = team base/HQ; ref i>=1 = capture point
## index (i-1), valid only if owned by the team. Server validates+places; client enumerates for
## the deploy screen. Position uses the same jitter as SpawnSelect to avoid stacking.

const JITTER := 6.0

static func enumerate(team: int, map: MapDef, conquest: ConquestState) -> Array:
	var refs: Array = [0]
	for i in conquest.points.size():
		if int(conquest.points[i]["owner"]) == team:
			refs.append(i + 1)
	return refs

static func is_valid(team: int, ref: int, map: MapDef, conquest: ConquestState) -> bool:
	if ref == 0:
		return not map.base_for(team).is_empty()
	var idx := ref - 1
	if idx < 0 or idx >= conquest.points.size():
		return false
	return int(conquest.points[idx]["owner"]) == team

static func resolve(team: int, ref: int, map: MapDef, conquest: ConquestState) -> Vector3:
	var src := Vector3.ZERO
	if ref == 0:
		var base: Dictionary = map.base_for(team)
		src = base["pos"] if not base.is_empty() else Vector3.ZERO
	else:
		src = conquest.points[ref - 1]["pos"]
	return Vector3(src.x + randf_range(-JITTER, JITTER), 0.0, src.z + randf_range(-JITTER, JITTER))
