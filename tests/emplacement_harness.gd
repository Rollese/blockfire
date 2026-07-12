class_name EmplacementHarness
extends RefCounted
## Deterministic, no-net harness for M19 P4 LMG-nest server tests. Acts AS the ServerEmplacement
## `srv` back-ref: exposes the minimal surface (_sim/_clients/_gadgets/_apply_pawn_damage/_fire) that
## faithfully reconstructs server_main's wiring, per the fob_functional_test.gd pattern.

var _sim: SimLoop
var _clients: Dictionary = {}
var _gadgets: Gadget
var emp: ServerEmplacement
var _fire                          # StubFire — deterministic stand-in for ServerFire.emplacement_hitscan
var dmg_log: Array = []            # records _apply_pawn_damage calls (for Task 9)
var _support_id := 7               # the manning Support player's pawn id

func _init() -> void:
	_sim = SimLoop.new()
	_gadgets = Gadget.load_file("res://data/gadgets.json")
	emp = ServerEmplacement.new(self)
	_fire = StubFire.new(self)

# ServerEmplacement + ServerFire.emplacement_hitscan call this in production (Task 9). Faithful to the
# real 7-param signature. Deterministic: subtract health, kill the pawn at 0. Records the call so tests
# can assert punishment happened.
func _apply_pawn_damage(vid: int, victim: Pawn, dmg: int, headshot: bool, source: int, killer_id: int, weapon_id: int) -> void:
	dmg_log.append({"victim": vid, "amount": dmg})
	var p: Pawn = victim if victim != null else _sim.world.get_pawn(vid)
	if p == null: return
	p.health = maxi(0, p.health - dmg)
	if p.health == 0:
		p.alive = false

## Register the Support player (with the LMG-nest gadget) at `pos`, return its pawn.
func add_support(pos: Vector3, team := 1) -> Pawn:
	var p := _sim.world.spawn(_support_id)
	p.team = team; p.pos = pos; p.alive = true; p.is_downed = false
	_clients[_support_id] = {"class": Loadout.SUPPORT, "loadout": {"gadget": Loadout.GADGET_LMG_NEST},
		"last_input": {"buttons": 0, "view_server_tick": 0}}
	return p

func support_pawn() -> Pawn:
	return _sim.world.get_pawn(_support_id)

func deploy(pos: Vector3, dir: Vector3) -> void:
	emp.deploy(_support_id, support_pawn(), pos, dir)

func nest_count() -> int:
	var n := 0
	for e in emp.nests.values():
		if (e as Emplacement).alive: n += 1
	return n

func first_nest() -> Emplacement:
	for e in emp.nests.values():
		if (e as Emplacement).alive: return e
	return null

func first_nest_id() -> int:
	var e := first_nest()
	return e.id if e != null else 0

func move_pawn_to(pos: Vector3) -> void:
	support_pawn().pos = pos

func set_pawn_yaw(rad: float) -> void:
	support_pawn().yaw = rad

func set_pawn_pitch(rad: float) -> void:
	support_pawn().pitch = rad

func pawn() -> Pawn:
	return support_pawn()

func pawn_id() -> int:
	return _support_id

func mount(nest_id: int) -> void:
	emp.mount(_support_id, support_pawn(), nest_id)

func dismount() -> void:
	emp.dismount(_support_id, support_pawn())

func tick() -> void:
	_sim.tick += 1
	emp.step_occupants()
	emp.step_fire()

var _next_enemy_id := 20

func add_enemy(pos: Vector3, team := 0) -> int:
	var id := _next_enemy_id
	_next_enemy_id += 1
	var p := _sim.world.spawn(id)
	p.team = team; p.pos = pos; p.alive = true; p.is_downed = false
	return id

func enemy_hp(id: int) -> int:
	var p := _sim.world.get_pawn(id)
	return p.health if p != null else -1

func set_fire(on: bool) -> void:
	_clients[_support_id]["last_input"]["buttons"] = (InputCommand.BTN_FIRE if on else 0)

func tick_now() -> int:
	return _sim.tick

## Deterministic stand-in for ServerFire.emplacement_hitscan: nearest enemy pawn on the ray takes dmg.
## No lag-comp / structure-LOS (the fleet gate proves those); this proves the fire STATE MACHINE + arc.
class StubFire extends RefCounted:
	var h
	func _init(harness) -> void:
		h = harness
	func emplacement_hitscan(shooter_id: int, team: int, origin: Vector3, dir: Vector3, dmg: int, rng: float, _supp: float) -> void:
		var best_t := rng + 1.0
		var best := 0
		for pid in h._sim.world.pawns:
			var p: Pawn = h._sim.world.pawns[pid]
			if pid == shooter_id or not p.alive or p.team == team: continue
			var hit := Hitbox.raycast_pawn(origin, dir, p.pos, p.stance, rng)
			if bool(hit["hit"]) and float(hit["t"]) < best_t:
				best_t = float(hit["t"]); best = pid
		if best != 0:
			h._apply_pawn_damage(best, h._sim.world.get_pawn(best), dmg, false, Revive.Source.BULLET, shooter_id, 0)
