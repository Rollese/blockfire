class_name SpawnSelect
extends Object
## Picks a spawn position for a (re)deploying player: the valid source nearest the
## objective, plus jitter to avoid stacking. Valid sources = home base, owned capture
## points, alive squadmates — never a neutral/enemy point, nor an owned point currently
## contested by enemies on it (BattleBit rule). Deterministic except for the jitter.
## See docs/specs/m3-conquest-squads.md.

const JITTER := 6.0

## squadmate_positions: Array[Vector3] of alive same-squad teammates (may be empty).
## objective: where the player wants to go (capture target / map point).
static func select(team: int, map: MapDef, conquest: ConquestState,
		squadmate_positions: Array, objective: Vector3) -> Vector3:
	var sources: Array[Vector3] = []
	var base := map.base_for(team)
	if not base.is_empty():
		sources.append(base["pos"])
	for i in conquest.points.size():
		var pt: Dictionary = conquest.points[i]
		# Owned, but not currently contested by enemies on it (BattleBit: no spawning on a
		# contested point). The home base is always a fallback, so this can't starve spawns.
		if int(pt["owner"]) == team and not conquest.point_contested_by_enemy(team, i):
			sources.append(pt["pos"])
	for sp in squadmate_positions:
		sources.append(sp)
	var chosen := sources[0] if sources.size() > 0 else Vector3.ZERO
	var best := INF
	for s in sources:
		var d: float = s.distance_to(objective)
		if d < best:
			best = d; chosen = s
	return Vector3(chosen.x + randf_range(-JITTER, JITTER), 0.0, chosen.z + randf_range(-JITTER, JITTER))
