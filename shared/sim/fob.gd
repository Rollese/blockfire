class_name Fob
extends Object
## Pure squad-leader-FOB rules (M12-P3). The FOB itself is a special large piece built through the
## M12-P2 build-site path; this file holds only the decisions that must be identical on server and
## (future M7) client: where a FOB may be placed, whether it may currently spawn (enemy proximity),
## and which squad member is the leader allowed to place it. No state, no I/O (AGENTS.md §5).

const MIN_BUILDERS := 2          # ≥2 simultaneous shovellers to advance the FOB site
const HEALTH := 2500             # bunker HP (matches pieces.json "fob"); high, M4-destructible
const BUILD_COST := 800          # shovel work to complete (matches pieces.json "fob")
const VICINITY_RADIUS := 40.0    # enemy within this (planar XZ) disables FOB spawning
const MAX_PER_SQUAD := 1         # active FOBs (site or built) per squad

## Planar XZ distance squared (Y ignored — bunkers/enemies on different floors still count).
static func _planar_d2(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return dx * dx + dz * dz

## A FOB site may be placed at `pos` by `team` iff: in a valid position, NOT inside an enemy-owned
## capture-point radius, and NOT inside the enemy home base radius. (Ground/bounds validity is the
## caller's StructureStore.validate_place; this adds the FOB-specific CP/base exclusion.)
static func placement_ok(pos: Vector3, team: int, map: MapDef, conquest: ConquestState) -> bool:
	for b in map.bases:
		if int(b["team"]) != team:
			var r := float(b.get("radius", 10.0))
			if _planar_d2(pos, b["pos"]) <= r * r:
				return false
	for i in conquest.points.size():
		var pt: Dictionary = conquest.points[i]
		if int(pt["owner"]) != team and int(pt["owner"]) != -1:
			var rr := float(pt.get("radius", 15.0))
			if _planar_d2(pos, pt["pos"]) <= rr * rr:
				return false
	return true

## The FOB at `fob_pos` may currently act as a spawn iff no enemy pawn is within VICINITY_RADIUS
## (planar XZ). `enemy_positions` is the set of alive enemy positions near the FOB (caller bounds it
## via the interest grid).
static func spawn_enabled(fob_pos: Vector3, enemy_positions: Array) -> bool:
	var r2 := VICINITY_RADIUS * VICINITY_RADIUS
	for e in enemy_positions:
		if _planar_d2(fob_pos, e) <= r2:
			return false
	return true

## Leader = the lowest client id in the squad. IDs are assigned sequentially on join and squads fill
## in join order, so the first member (the leader) always holds the minimum id among its squadmates.
## `visible_squad_ids` is what the inferring agent can see (must include its own id).
## NOTE: this lowest-id == first-member identity holds for auto-assigned squads; a manual squad switch
## (SquadManager.join) can append a member out of id order, so the server stays authoritative via
## SquadManager.leader_of(). This helper is the bots' / future M7 client's best-effort inference only.
static func is_squad_leader(my_id: int, visible_squad_ids: Array) -> bool:
	for other in visible_squad_ids:
		if int(other) < my_id:
			return false
	return true
