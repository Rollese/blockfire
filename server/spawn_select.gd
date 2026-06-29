class_name SpawnSelect
extends Object
## Picks a spawn position for a (re)deploying player: the valid source nearest the
## objective, plus jitter to avoid stacking. Valid sources = home base, owned capture
## points, alive squadmates, squad FOB — never a neutral/enemy point, nor an owned point
## currently contested by enemies on it (BattleBit rule). Deterministic except for the jitter.
## See docs/specs/m3-conquest-squads.md.

const JITTER := 6.0

enum { SRC_BASE, SRC_POINT, SRC_MATE, SRC_FOB }

## Like select(), but returns {pos: Vector3, kind: int}. `fob_positions` are this team's
## currently-spawnable FOBs (completed + alive + enemy-free; the server pre-filters).
static func choose(team: int, map: MapDef, conquest: ConquestState,
		squadmate_positions: Array, objective: Vector3, fob_positions: Array = []) -> Dictionary:
	var sources: Array = []   # [{pos, kind}]
	var base := map.base_for(team)
	if not base.is_empty():
		sources.append({"pos": base["pos"], "kind": SRC_BASE})
	for i in conquest.points.size():
		var pt: Dictionary = conquest.points[i]
		# Owned, but not currently contested by enemies on it (BattleBit: no spawning on a
		# contested point). The home base is always a fallback, so this can't starve spawns.
		if int(pt["owner"]) == team and not conquest.point_contested_by_enemy(team, i):
			sources.append({"pos": pt["pos"], "kind": SRC_POINT})
	for sp in squadmate_positions:
		sources.append({"pos": sp, "kind": SRC_MATE})
	for fp in fob_positions:
		sources.append({"pos": fp, "kind": SRC_FOB})
	var chosen: Dictionary = sources[0] if sources.size() > 0 else {"pos": Vector3.ZERO, "kind": SRC_BASE}
	var best := INF
	for s in sources:
		var d: float = (s["pos"] as Vector3).distance_to(objective)
		if d < best:
			best = d; chosen = s
	var c: Vector3 = chosen["pos"]
	return {"pos": Vector3(c.x + randf_range(-JITTER, JITTER), 0.0, c.z + randf_range(-JITTER, JITTER)),
		"kind": int(chosen["kind"])}

## squadmate_positions: Array[Vector3] of alive same-squad teammates (may be empty).
## objective: where the player wants to go (capture target / map point).
## fob_positions: Array[Vector3] of this team's currently-spawnable FOBs (optional).
static func select(team: int, map: MapDef, conquest: ConquestState,
		squadmate_positions: Array, objective: Vector3, fob_positions: Array = []) -> Vector3:
	return choose(team, map, conquest, squadmate_positions, objective, fob_positions)["pos"]
