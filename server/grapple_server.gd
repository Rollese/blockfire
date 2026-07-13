class_name ServerDeployedLadders
extends RefCounted
## Server store for deployed grapple ladders (M19 Assault grapple). `volumes` is the single source of
## truth: it is BOTH the SimLoop climb array (Ladder.capture reads bottom/top/radius) and the render-list
## source (build_list reads id/x/z/bottom_y/top_y/cuttable). Mirrors ServerEmplacement's owner-keyed
## deploy/eviction. `srv` is the ServerMain back-ref (exposes _clients/_sim/_store).
##
## IN-PLACE CONTRACT: Task 6 wires SimLoop.deployed_ladders = _grapples.volumes BY REFERENCE. Every
## removal path (evict/cut/remove_building/clear) therefore MUTATES the SAME Array object (via
## Array.assign()/clear()) — never reassigns `volumes` to a fresh Array — so that shared reference
## never goes stale.

const Terrain := preload("res://shared/sim/terrain.gd")
const Ladder := preload("res://shared/sim/ladder.gd")

var srv                        # ServerMain back-ref
var volumes: Array = []        # ladder dicts; shared BY REFERENCE with SimLoop.deployed_ladders (never reassigned)
var _next_index := 0

func _init(server) -> void:
	srv = server

## Fire a hook: march the aim ray for an anchor, resolve, spend a charge, evict the owner's prior
## ladder, add the new one. Server-authoritative — gates gadget/charge/downed/mount/vehicle.
func deploy(owner_id: int, p: Pawn, pos: Vector3, dir: Vector3) -> void:
	if p == null or not p.alive: return
	var c = srv._clients.get(owner_id)
	if c == null or int(c["loadout"]["gadget"]) != Loadout.GADGET_GRAPPLE: return
	if int(c.get("grapple_charges", 0)) <= 0: return
	if p.is_downed or p.climbing or p.vaulting or p.mounted_nest != 0 or p.in_vehicle != 0: return
	if srv._store == null: return
	var d := dir.normalized() if dir.length() > 0.001 else Vector3(sin(p.yaw), 0.0, cos(p.yaw))
	var m = srv._store.march(p.eye_position(), d, Grapple.MAX_RANGE)
	if not bool(m["hit"]): return
	var hit_point: Vector3 = p.eye_position() + d * float(m["dist"])
	var bid := srv._store.building_id_of(int(m["id"])) as int   # 0 for a terrain hit
	var ground_y := _ground_at(hit_point.x, hit_point.z)
	var r := Grapple.resolve(p.eye_position(), hit_point, ground_y, true)
	if not bool(r["ok"]): return
	c["grapple_charges"] = int(c["grapple_charges"]) - 1
	_evict_owner(owner_id)
	_add(owner_id, bid, r)

## Test-only convenience: skip the march and deploy from an already-resolved hit point.
func deploy_at(owner_id: int, p: Pawn, hit_point: Vector3, building_id: int, ground_y: float) -> void:
	var c = srv._clients.get(owner_id)
	if c == null or int(c.get("grapple_charges", 0)) <= 0: return
	var r := Grapple.resolve(p.eye_position(), hit_point, ground_y, true)
	if not bool(r["ok"]): return
	c["grapple_charges"] = int(c["grapple_charges"]) - 1
	_evict_owner(owner_id)
	_add(owner_id, building_id, r)

func _add(owner_id: int, building_id: int, r: Dictionary) -> void:
	var id := 0x50000000 + _next_index   # dedicated id space, clear of pawn/piece ids
	_next_index += 1
	var x := float(r["x"]); var z := float(r["z"])
	volumes.append({
		"id": id, "owner_id": owner_id, "building_id": building_id,
		"deploy_tick": int(srv._sim.tick), "cuttable": false,
		"x": x, "z": z, "bottom_y": float(r["bottom_y"]), "top_y": float(r["top_y"]),
		"bottom": Vector3(x, float(r["bottom_y"]), z),
		"top": Vector3(x, float(r["top_y"]), z),
		"radius": Grapple.LADDER_RADIUS,
	})

func _evict_owner(owner_id: int) -> void:
	var kept: Array = []
	for l in volumes:
		if int(l["owner_id"]) != owner_id: kept.append(l)
	volumes.assign(kept)   # in-place: keep the shared Array object

## Cut request from `requester_id` (any team). Validates cuttable arm-age + within CUT_RADIUS.
func cut(requester_id: int, ladder_id: int, requester: Pawn) -> void:
	if requester == null or not requester.alive or requester.is_downed: return
	var kept: Array = []
	var removed := false
	for l in volumes:
		if int(l["id"]) == ladder_id and not removed:
			var age := int(srv._sim.tick) - int(l["deploy_tick"])
			var dist := Vector2(requester.pos.x - float(l["x"]), requester.pos.z - float(l["z"])).length()
			if Grapple.can_cut(age, dist):
				removed = true
				continue
		kept.append(l)
	if removed:
		volumes.assign(kept)   # in-place

## Flip cuttable once each ladder passes the arm delay (called once per tick). Mutates dicts in place.
func step_arm(tick: int) -> void:
	for l in volumes:
		if not bool(l["cuttable"]) and tick - int(l["deploy_tick"]) >= Grapple.CUT_ARM_TICKS:
			l["cuttable"] = true

func remove_owner(owner_id: int) -> void:
	_evict_owner(owner_id)

func remove_building(building_id: int) -> void:
	if building_id == 0: return
	var kept: Array = []
	for l in volumes:
		if int(l["building_id"]) != building_id: kept.append(l)
	volumes.assign(kept)   # in-place

## Render list (self-healing, bounded). Wire fields only.
func build_list() -> Array:
	var out: Array = []
	for l in volumes:
		if out.size() >= 255: break
		out.append({"id": l["id"], "x": l["x"], "z": l["z"],
			"bottom_y": l["bottom_y"], "top_y": l["top_y"], "cuttable": l["cuttable"]})
	return out

func clear() -> void:
	volumes.clear()   # in-place
	_next_index = 0

func _ground_at(x: float, z: float) -> float:
	var ty := 0.0
	if srv._sim != null and srv._sim.terrain != null:
		ty = Terrain.height_at(srv._sim.terrain, x, z)
	var pf := Ladder.platform_floor(srv._sim.platforms, x, z, 1e9) if srv._sim != null else -INF
	return maxf(ty, pf) if pf > -INF else ty
