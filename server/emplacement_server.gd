class_name ServerEmplacement
extends RefCounted
## Server-side LMG-nest pipeline (M19 P4): deploy (this task) + mount/dismount/fire/destroy (later
## tasks), plus the EMPLACEMENT_LIST render broadcast. Owns the live nest store; all decisions defer
## to Emplacement static rules so server authority matches client prediction / tests. Modeled on
## server/support.gd (RefCounted with a `srv` back-ref).

const Terrain := preload("res://shared/sim/terrain.gd")
const MAX_NESTS := 64   # explicit render-list bound (GadgetList.MAX precedent); nests are one-per-owner.

var srv                        # ServerMain back-ref (or EmplacementHarness in tests)
var nests: Dictionary = {}     # id -> Emplacement
var _next_index := 0

func _init(server) -> void:
	srv = server

func _def() -> Dictionary:
	return srv._gadgets.def_of_kind(Gadget.KIND_LMG_NEST)

## Deploy at the owner's aim point/facing. Validates the gadget is equipped, ground-snaps, enforces
## min separation from other nests, and one-active-nest-per-owner.
func deploy(owner_id: int, p: Pawn, pos: Vector3, dir: Vector3) -> void:
	if p == null: return
	var c = srv._clients.get(owner_id)
	if c == null or int(c["loadout"]["gadget"]) != Loadout.GADGET_LMG_NEST: return
	if dir.length() < 0.001: return
	var def := _def()
	var snapped := pos
	snapped.y = Terrain.height_at(srv._sim.terrain, snapped.x, snapped.z)
	# one active nest per owner: drop the owner's prior nest(s) FIRST so a redeploy near your own
	# current nest isn't blocked by the separation check below.
	for eid in nests.keys():
		if int((nests[eid] as Emplacement).owner_id) == owner_id:
			nests.erase(eid)
	# separation now only guards against OTHER owners' nests
	for e: Emplacement in nests.values():
		if e.alive and e.pos.distance_to(snapped) < float(def.get("min_sep_m", 4.0)):
			return
	var facing := atan2(dir.x, dir.z)
	var e := Emplacement.make(Emplacement.id_for(_next_index), Gadget.KIND_LMG_NEST, p.team, snapped, facing, def)
	e.owner_id = owner_id
	nests[e.id] = e
	_next_index += 1

func get_nest(nest_id: int) -> Emplacement:
	return nests.get(nest_id)

## Rebuild the render list from live state (self-healing). Bounded by MAX_NESTS.
func build_list() -> Array:
	var out: Array = []
	for e: Emplacement in nests.values():
		if not e.alive: continue
		if out.size() >= MAX_NESTS: break
		out.append({"id": e.id, "pos": e.pos, "facing_yaw": e.facing_yaw, "turret_yaw": e.turret_yaw,
			"hp_frac": float(e.hp) / float(maxi(1, e.max_hp)), "occupant": e.occupant, "team": e.team})
	return out

func clear() -> void:
	nests.clear()
	_next_index = 0
