class_name Emplacement
extends RefCounted
## Authoritative manned MG-emplacement entity (M19 P4). Immobile single-gunner: it does NOT move
## or run a physics step (unlike Vehicle). It copies the vehicle gunner *patterns* — seat occupancy,
## clamped turret aim, mounted-gun fire, whole-entity HP — into a dedicated class so the parked
## vehicle system stays untouched. Static helpers are pure (server/client agree, unit-testable).

const ID_BASE := 0x50000000   # disjoint from pawn ids (1..128) and Vehicle.ID_BASE (0x40000000)
const SEAT_BACK := 0.6        # gunner sits this far BEHIND the pivot (-forward), at ground
const MUZZLE_FWD := 0.8       # muzzle this far in FRONT of the pivot
const MUZZLE_UP := 1.1        # muzzle height (mounted gun sits ~waist/chest high)

var id: int = 0
var type: int = 0            # gadget kind (Gadget.KIND_LMG_NEST) — future-proof for variants
var owner_id: int = 0
var team: int = 0
var pos: Vector3 = Vector3.ZERO
var facing_yaw: float = 0.0  # centre of the traverse arc (deploy facing)
var turret_yaw: float = 0.0  # current aim yaw (within arc)
var pitch: float = 0.0       # current aim pitch (within pitch clamp)
var occupant: int = 0        # manning pawn id, 0 = unmanned
var hp: int = 0
var max_hp: int = 0
var heat: int = 0
var overheated_until: int = 0
var ammo: int = 0            # belt rounds remaining
var reloading_until: int = 0
var last_fire_tick: int = -100000
var alive: bool = true

static func id_for(index: int) -> int:
	return ID_BASE + index

static func make(p_id: int, p_type: int, p_team: int, p_pos: Vector3, p_facing: float, def: Dictionary) -> Emplacement:
	var e := Emplacement.new()
	e.id = p_id
	e.type = p_type
	e.team = p_team
	e.pos = p_pos
	e.facing_yaw = p_facing
	e.turret_yaw = p_facing
	e.max_hp = int(def.get("hp", 500)); e.hp = e.max_hp
	e.ammo = int(def.get("belt", 150))
	return e

## Yaw forward on the codebase convention forward=(sin,0,cos).
static func yaw_forward(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))

## Shortest signed angular difference a-b in [-PI, PI).
static func ang_diff(a: float, b: float) -> float:
	return wrapf(a - b, -PI, PI)

## Clamp an aim yaw into [facing - half_arc, facing + half_arc], wrap-aware. Returns a value
## NORMALIZED into [-PI, PI) so it never overflows the i16 yaw packing (facing near ±PI could
## otherwise push facing+arc past PI). Direction is identical; only the representation wraps.
static func clamp_yaw(yaw: float, facing: float, half_arc: float) -> float:
	var d := ang_diff(yaw, facing)
	return wrapf(facing + clampf(d, -half_arc, half_arc), -PI, PI)

## Clamp pitch into [-lo, hi]. `lo`/`hi` are POSITIVE magnitudes (down/up limits); lo is negated here.
static func clamp_pitch(p: float, lo: float, hi: float) -> float:
	return clampf(p, -lo, hi)

static func can_mount(e: Emplacement, p: Pawn, dist: float, mount_range: float) -> bool:
	if e == null or p == null: return false
	return e.alive and e.occupant == 0 and p.alive and not p.is_downed \
		and p.mounted_nest == 0 and p.in_vehicle == 0 and e.team == p.team and dist <= mount_range

static func overheated(overheated_until: int, tick: int) -> bool:
	return tick < overheated_until

## Heat integration mirroring Gadget.repair_heat_step: firing raises heat to a cap -> lockout;
## not firing decays. Returns {heat:int, overheated_until:int}.
static func heat_step(heat: int, overheated_until: int, tick: int, firing: bool, overheat_ticks: int, cooldown_ticks: int) -> Dictionary:
	if tick < overheated_until:
		return {"heat": 0, "overheated_until": overheated_until}
	if not firing:
		return {"heat": maxi(0, heat - 1), "overheated_until": 0}
	var h := heat + 1
	if h >= overheat_ticks:
		return {"heat": 0, "overheated_until": tick + cooldown_ticks}
	return {"heat": h, "overheated_until": 0}

func seat_world() -> Vector3:
	return pos - yaw_forward(facing_yaw) * SEAT_BACK

func muzzle() -> Vector3:
	return pos + yaw_forward(facing_yaw) * MUZZLE_FWD + Vector3(0.0, MUZZLE_UP, 0.0)

## Apply `amount` damage. On death, mark not-alive and clear the occupant (server ejects/punishes).
func hit(amount: int, _tick: int) -> void:
	if not alive: return
	hp = maxi(0, hp - amount)
	if hp == 0:
		alive = false
		occupant = 0
