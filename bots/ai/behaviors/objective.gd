class_name AiObjective
extends RefCounted
## Re-homed objective selection + ladder-seek (was static on BotDriver). Logic unchanged
## (docs/specs/bot-ai.md §4 helper migration). Constants moved with the code.

const CLIMB_SEEK_RANGE := 16.0   # m: consider a ladder only when this close to its base
const CLIMB_TOP_MARGIN := 2.0    # m above the ladder bottom past which the bot is "up" already

const TOP_K := 3                  # squads fan out across this many nearest capturable points
const ENEMY_OWNED_BIAS := 0.75    # distance discount pulling squads onto enemy-held points
const MARCH_SPREAD_SPACING := 2.0 # m between adjacent march lanes
const MARCH_SPREAD_LANES := 4     # lanes -N..+N around the direct line (width = N*spacing each side)
const MARCH_CONVERGE_RANGE := 20.0 # m from the objective where lanes start collapsing onto it

## Pure objective selector (unit-tested). Among points NOT owned by `my_team`, rank by distance
## from `from` (enemy-owned points get a distance discount so attacks push into held ground),
## then squad-hash across the TOP_K nearest so different squads fan out instead of stacking on
## the single nearest point — the flank/spread fix (2026-07-02 investigation §E): the old
## nearest-only pick split symmetric maps into two non-meeting columns. Same squad -> same pick
## (cohesion); if the team owns every point, defend the nearest one. `owners[i]` is the owner
## of points[i] (-1 neutral); owners shorter than points defaults missing entries to neutral.
## Returns -1 iff points is empty.
static func choose_objective_spread(points: Array, owners: Array, my_team: int, from: Vector3, squad_key: int) -> int:
	if points.is_empty():
		return -1
	var cands: Array[Dictionary] = []
	for i in points.size():
		var owner := -1
		if i < owners.size():
			owner = int(owners[i])
		if owner == my_team:
			continue   # already ours — skip while capturable points remain
		var d: float = from.distance_to(points[i])
		if owner != -1:
			d *= ENEMY_OWNED_BIAS   # enemy-owned/contested: worth a longer walk
		cands.append({"i": i, "d": d})
	if cands.is_empty():
		# team owns every capturable point: defend the nearest one to `from`
		var best := -1
		var best_d := INF
		for i in points.size():
			var fd: float = from.distance_to(points[i])
			if fd < best_d:
				best_d = fd; best = i
		return best
	cands.sort_custom(func(a, b): return a["d"] < b["d"] or (a["d"] == b["d"] and a["i"] < b["i"]))
	return int(cands[posmod(squad_key, mini(TOP_K, cands.size()))]["i"])

## Per-bot lateral march lane: offset the objective perpendicular to the from->objective line so
## a squad advances as a line abreast, not a single-file column (spread part of the flank fix).
## The offset fades linearly inside MARCH_CONVERGE_RANGE so everyone still converges on the
## capture zone. Pure; `spread_key` is any stable per-bot int (bot index).
static func spread_march_target(from: Vector3, objective: Vector3, spread_key: int) -> Vector3:
	var flat := Vector2(objective.x - from.x, objective.z - from.z)
	var dist := flat.length()
	if dist < 0.001:
		return objective
	var dirn := flat / dist
	var lane := posmod(spread_key, 2 * MARCH_SPREAD_LANES + 1) - MARCH_SPREAD_LANES
	var mag := float(lane) * MARCH_SPREAD_SPACING
	if dist < MARCH_CONVERGE_RANGE:
		mag *= dist / MARCH_CONVERGE_RANGE
	# perpendicular in the XZ plane (right-hand of the march direction)
	return objective + Vector3(dirn.y, 0.0, -dirn.x) * mag

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
