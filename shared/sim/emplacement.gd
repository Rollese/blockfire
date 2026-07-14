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

# Sandbag-parapet collision volume in nest-LOCAL space (x=right, y=up, z=facing-forward). A
# conservative facing-aligned box approximating the curved parapet, used for the bullet-chip ray
# test. ~2.2 m wide, up to the parapet top (1.92 m from the G3 art), bulging forward of the pivot.
const NEST_BOX_MIN := Vector3(-1.1, 0.0, -0.4)
const NEST_BOX_MAX := Vector3(1.1, 1.92, 0.8)

## Nearest ALIVE nest whose pivot is within melee reach and inside the attacker's frontal cone; 0 if
## none. Team-agnostic on purpose — a sledge tears down ANY nest (friendly or enemy) like other
## deployables. Mirrors Melee.best_target's reach + frontal-dot gate. Pure (unit-tested).
static func nearest_meleeable(attacker_pos: Vector3, attacker_yaw: float, nests: Dictionary) -> int:
	var fwd := yaw_forward(attacker_yaw)
	var reach := Melee.MELEE_RANGE
	var best := 0
	var best_d := reach + 1.0
	for nid in nests:
		var e: Emplacement = nests[nid]
		if e == null or not e.alive:
			continue
		var to: Vector3 = e.pos - attacker_pos
		var flat := Vector3(to.x, 0.0, to.z)
		var d := flat.length()
		if d > reach or d < 0.001:
			continue
		if flat.normalized().dot(fwd) < 0.3:   # not in front (matches Melee.best_target)
			continue
		if d < best_d:
			best_d = d
			best = int(nid)
	return best

## Entry distance (>=0) where `origin + dir*t` first enters this nest's parapet box within
## [0, max_dist], or -1.0 for a miss / dead nest. Pure ray-vs-oriented-box (slab test in nest-local
## space), used for small-arms bullet-chip. `dir` is expected unit-length; `max_dist` bounds the test
## to one projectile segment. Origin inside the box returns 0.0.
static func ray_hits_nest(origin: Vector3, dir: Vector3, max_dist: float, e: Emplacement) -> float:
	if e == null or not e.alive:
		return -1.0
	var f := yaw_forward(e.facing_yaw)          # local +z
	var r := Vector3(f.z, 0.0, -f.x)            # local +x (forward rotated -90 about Y)
	var w := origin - e.pos
	var lo := Vector3(w.dot(r), w.y, w.dot(f))
	var ld := Vector3(dir.dot(r), dir.y, dir.dot(f))
	var tmin := 0.0
	var tmax := max_dist
	# x / y / z slabs
	for axis in 3:
		var o: float = lo[axis]
		var dd: float = ld[axis]
		var mn: float = NEST_BOX_MIN[axis]
		var mx: float = NEST_BOX_MAX[axis]
		if absf(dd) < 1e-9:
			if o < mn or o > mx:
				return -1.0                       # parallel to this slab and outside it
			continue
		var t1 := (mn - o) / dd
		var t2 := (mx - o) / dd
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	return tmin

## Apply `amount` damage. On death, mark not-alive and clear the occupant (server ejects/punishes).
func hit(amount: int, _tick: int) -> void:
	if not alive: return
	hp = maxi(0, hp - amount)
	if hp == 0:
		alive = false
		occupant = 0
