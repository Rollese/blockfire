class_name AiObjective
extends RefCounted
## Re-homed objective selection + ladder-seek (was static on BotDriver). Logic unchanged
## (docs/specs/bot-ai.md §4 helper migration). Constants moved with the code.

const CLIMB_SEEK_RANGE := 16.0   # m: consider a ladder only when this close to its base
const CLIMB_TOP_MARGIN := 2.0    # m above the ladder bottom past which the bot is "up" already

## Pure objective selector (unit-tested). Among points NOT owned by `my_team`, pick the one
## nearest `center` (tie-broken by distance from `from`); if the team owns every point,
## defend the nearest point to `from`. `owners[i]` is the owner of points[i] (-1 neutral);
## owners shorter than points defaults missing entries to neutral. Returns -1 iff points is
## empty. Biasing toward the map center makes both teams contest the same points so the match
## converges into combat. See docs/specs/m3-bot-convergence-fix.md.
static func choose_objective_index(points: Array, owners: Array, my_team: int, from: Vector3, center: Vector3) -> int:
	if points.is_empty():
		return -1
	var best := -1
	var best_c := INF
	var best_d := INF
	for i in points.size():
		var owner := -1
		if i < owners.size():
			owner = int(owners[i])
		if owner == my_team:
			continue   # already ours — skip while capturable points remain
		var cd: float = center.distance_to(points[i])
		var fd: float = from.distance_to(points[i])
		if cd < best_c - 0.001 or (absf(cd - best_c) <= 0.001 and fd < best_d):
			best_c = cd; best_d = fd; best = i
	if best == -1:
		# team owns every capturable point: defend the nearest one to `from`
		for i in points.size():
			var fd: float = from.distance_to(points[i])
			if fd < best_d:
				best_d = fd; best = i
	return best

## Decide whether to steer onto a ladder. seek=true with a move target at the ladder base when the
## bot is near a ladder (and still below it) and its objective is roughly across/beyond that ladder.
## Pure + unit-tested. The height guard stops a bot that has reached the ledge from re-seeking the
## same ladder and getting stuck pushing "up" at the top.
static func climb_seek(my_pos: Vector3, objective: Vector3, ladders: Array) -> Dictionary:
	for l in ladders:
		var base: Vector3 = l["bottom"]
		if my_pos.y > base.y + CLIMB_TOP_MARGIN:
			continue   # already elevated (on/above the ledge) — don't re-seek this ladder
		var to_base := Vector2(base.x - my_pos.x, base.z - my_pos.z)
		if to_base.length() > CLIMB_SEEK_RANGE:
			continue
		var to_obj := Vector2(objective.x - my_pos.x, objective.z - my_pos.z)
		# Objective is beyond the ladder (same general heading, farther away).
		if to_obj.length() > to_base.length() and to_base.normalized().dot(to_obj.normalized()) > 0.3:
			return {"seek": true, "target": base}
	return {"seek": false, "target": my_pos}

## Index of the capture point nearest the map centre (origin) — the most contested objective, where
## combat (and thus the blast fire that can damage a vehicle) concentrates. -1 for an empty list.
static func central_point_index(positions: Array) -> int:
	var best := -1
	var bestd := INF
	for i in positions.size():
		var d: float = (positions[i] as Vector3).length()   # distance from origin
		if d < bestd:
			bestd = d; best = i
	return best
