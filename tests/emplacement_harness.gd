class_name EmplacementHarness
extends RefCounted
## Deterministic, no-net harness for M19 P4 LMG-nest server tests. Acts AS the ServerEmplacement
## `srv` back-ref: exposes the minimal surface (_sim/_clients/_gadgets/_apply_pawn_damage/_fire) that
## faithfully reconstructs server_main's wiring, per the fob_functional_test.gd pattern.

var _sim: SimLoop
var _clients: Dictionary = {}
var _gadgets: Gadget
var emp: ServerEmplacement
var dmg_log: Array = []            # records _apply_pawn_damage calls (for Task 9)
var _support_id := 7               # the manning Support player's pawn id

func _init() -> void:
	_sim = SimLoop.new()
	_gadgets = Gadget.load_file("res://data/gadgets.json")
	emp = ServerEmplacement.new(self)

# ServerEmplacement calls this in production (Task 9). Simple deterministic version: subtract health,
# down/kill the pawn. Records the call so tests can assert punishment happened.
func _apply_pawn_damage(victim_id: int, attacker_id: int, amount: int, headshot: bool, weapon: int) -> void:
	dmg_log.append({"victim": victim_id, "amount": amount})
	var p: Pawn = _sim.world.get_pawn(victim_id)
	if p == null: return
	p.health = maxi(0, p.health - amount)
	if p.health == 0:
		p.alive = false

## Register the Support player (with the LMG-nest gadget) at `pos`, return its pawn.
func add_support(pos: Vector3, team := 1) -> Pawn:
	var p := _sim.world.spawn(_support_id)
	p.team = team; p.pos = pos; p.alive = true; p.is_downed = false
	_clients[_support_id] = {"class": Loadout.SUPPORT, "loadout": {"gadget": Loadout.GADGET_LMG_NEST}}
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

func tick() -> void:
	_sim.tick += 1
	# later tasks call emp.step_occupants()/emp.step_fire(...) here
