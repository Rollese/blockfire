class_name AiVehicleCrew
extends RefCounted
## Re-homed M5 vehicle helpers + structure-mirror apply. PRESERVED FOR THE M5 GATE;
## NOT part of M7.5 infantry AI scope (docs/specs/bot-ai.md §4, §16). Logic unchanged.

## Apply a decoded STRUCTURE_DELTA to a bot's local mirror (id->record). PLACE inserts, DAMAGE
## updates the record's bucket in place (must NOT remove), REMOVE erases. Pure + unit-tested;
## the live path runs inside _on_packet. See docs/specs/destruction.md.
static func apply_structure_delta(structs: Dictionary, d: Dictionary) -> void:
	var op: int = d["op"]
	if op == Protocol.OP_PLACE:
		structs[d["rec"]["id"]] = d["rec"]
	elif op == Protocol.OP_DAMAGE:
		var id: int = d["id"]
		if structs.has(id):
			structs[id]["bucket"] = d["bucket"]
	else:
		structs.erase(d["id"])

## Position of the nearest alive enemy pawn in `view` (pawn_id -> EntityState with .alive/.team/.pos),
## excluding my own id. Returns {"found": bool, "pos": Vector3}. Used to drive a crewed transport into
## the firefight so the vehicle draws blast fire.
static func nearest_enemy_pos(view: Dictionary, my_id: int, my_team: int, my_pos: Vector3) -> Dictionary:
	var best := INF
	var bp := Vector3.ZERO
	var found := false
	for id in view:
		if int(id) == my_id: continue
		var e: EntityState = view[id]
		if not e.alive or int(e.team) == my_team: continue
		var d: float = my_pos.distance_to(e.pos)
		if d < best:
			best = d; bp = e.pos; found = true
	return {"found": found, "pos": bp}

## Position of the ENEMY team's vehicle spawn (a fixed deep-enemy-backfield point). Crewed transports
## drive here to loiter in enemy fire so the vehicle takes blast damage (the only thing that hurts it).
## spawns: Array of {team:int, pos:Vector3}. Returns `fallback` if no enemy spawn is listed.
static func enemy_spawn_pos(spawns: Array, my_team: int, fallback: Vector3) -> Vector3:
	for s in spawns:
		if int(s["team"]) != my_team:
			return s["pos"]
	return fallback

## A vehicle is "enemy" if any seated occupant is a pawn on the other team (per the pawn view).
## Empty / friendly-crewed vehicles return false. view: pawn_id -> EntityState (must expose .team).
static func vehicle_is_enemy(v: VehicleState, view: Dictionary, my_team: int) -> bool:
	for occ in v.seats:
		var oid := int(occ)
		if oid == 0: continue
		var e = view.get(oid)
		if e != null and int(e.team) != my_team:
			return true
	return false

## Nearest enemy-crewed vehicle within max_dist of my_pos. Returns vid or 0.
static func nearest_enemy_vehicle(vview: Dictionary, view: Dictionary, my_pos: Vector3, my_team: int, max_dist: float) -> int:
	var best := 0
	var bestd := max_dist
	for vid in vview:
		var v: VehicleState = vview[vid]
		if not vehicle_is_enemy(v, view, my_team): continue
		var d := my_pos.distance_to(v.pos)
		if d <= bestd:
			bestd = d; best = vid
	return best

## Nearest own-vehicle (vehicles are team-locked so any replicated one is enterable) with a free
## seat, within reason. Returns vid or 0. seats[*]==0 means empty.
static func nearest_free_vehicle(vview: Dictionary, my_pos: Vector3) -> int:
	var best := 0
	var bestd := INF
	for vid in vview:
		var v: VehicleState = vview[vid]
		var free := false
		for occ in v.seats:
			if int(occ) == 0: free = true; break
		if not free: continue
		var d := my_pos.distance_to(v.pos)
		if d < bestd:
			bestd = d; best = vid
	return best

## Vehicle driver command toward `objective` from `from`, given the vehicle's current `heading`.
## move_x = steering (proportional to the heading error, so the hull turns to face the target),
## move_y = throttle. yaw = bearing (pawn look). Forward convention matches Vehicle.step:
## forward = (sin(heading), 0, cos(heading)); a positive steer increases heading (+Z -> +X).
static func drive_toward(heading: float, from: Vector3, objective: Vector3) -> Dictionary:
	var to := objective - from
	var bearing := atan2(to.x, to.z)
	var err := wrapf(bearing - heading, -PI, PI)
	var steer := clampf(err * 2.0, -1.0, 1.0)
	return {"move_x": steer, "move_y": 1.0, "yaw": bearing}
