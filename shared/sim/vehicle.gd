class_name Vehicle
extends RefCounted
## Authoritative vehicle entity. Custom-kinematic (deterministic; M7-prediction-ready). Built from
## a VehicleCatalog def via make(). Seats are seat-index -> occupant pawn id (0 = empty). Physics
## lives in step() (Task 4); geometry/enter-exit helpers here. See docs/specs/vehicles.md.

const ROLE_DRIVER := 0
const ROLE_PASSENGER := 1
const ROLE_GUNNER := 2
const ID_BASE := 0x40000000   # disjoint from pawn ids (1..128); keeps the fire grid pawn-only
const GRAVITY := 20.0
const WORLD_HALF := 1000.0
const TURN_FULL_SPEED := 6.0   # m/s at/above which steering has full authority (no standstill pivot)

const _ROLES := {"driver": ROLE_DRIVER, "passenger": ROLE_PASSENGER, "gunner": ROLE_GUNNER}

var id: int = 0
var type: int = 0
var team: int = 0
var pos: Vector3 = Vector3.ZERO
var heading: float = 0.0
var turret_yaw: float = 0.0
var velocity: Vector3 = Vector3.ZERO
var speed: float = 0.0          # signed longitudinal speed (m/s)
var hp: int = 0
var alive: bool = true
var respawn_tick: int = 0
var last_mounted_fire_tick: int = -100000
var spawn_pos: Vector3 = Vector3.ZERO

# copied from def at make()
var max_hp: int = 0
var max_speed: float = 0.0
var reverse_speed: float = 0.0
var accel: float = 0.0
var drag: float = 0.0
var turn_rate: float = 0.0
var respawn_ticks: int = 450
var turret_offset: Vector3 = Vector3.ZERO
var exit_offset: Vector3 = Vector3.ZERO
var mounted: Dictionary = {}
var seat_offsets: Array = []    # Array[Vector3]
var seat_roles: Array = []      # Array[int]
var seats: Array = []           # Array[int] occupant ids, 0 = empty

static func id_for(index: int) -> int:
	return ID_BASE + index

static func _v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func make(p_id: int, p_type: int, def: Dictionary, p_team: int, p_pos: Vector3) -> Vehicle:
	var v := Vehicle.new()
	v.id = p_id
	v.type = p_type
	v.team = p_team
	v.pos = p_pos
	v.spawn_pos = p_pos
	v.max_hp = int(def["max_hp"]); v.hp = v.max_hp
	v.max_speed = float(def["max_speed"])
	v.reverse_speed = float(def["reverse_speed"])
	v.accel = float(def["accel"])
	v.drag = float(def["drag"])
	v.turn_rate = float(def["turn_rate"])
	v.respawn_ticks = int(def["respawn_ticks"])
	v.turret_offset = _v3(def["turret_offset"])
	v.exit_offset = _v3(def["exit_offset"])
	v.mounted = def.get("mounted_weapon", {})
	for s in def["seats"]:
		v.seat_offsets.append(_v3(s["offset"]))
		v.seat_roles.append(int(_ROLES.get(String(s["role"]), ROLE_PASSENGER)))
		v.seats.append(0)
	return v

## Rotate a body-local offset (x=right, y=up, z=forward) into world space by yaw.
## Matches the codebase yaw convention forward=(sin,0,cos), right=(cos,0,-sin).
static func rotate_yaw(off: Vector3, yaw: float) -> Vector3:
	var s := sin(yaw); var c := cos(yaw)
	return Vector3(off.x * c + off.z * s, off.y, -off.x * s + off.z * c)

## Steering authority by speed: 0 at rest (no wheeled pivot), full at/above TURN_FULL_SPEED.
static func turn_factor(spd: float, _max_speed: float) -> float:
	return clampf(absf(spd) / TURN_FULL_SPEED, 0.0, 1.0)

static func can_enter(v: Vehicle, p: Pawn, dist: float, enter_range: float) -> bool:
	if v == null or p == null: return false
	return p.alive and not p.is_downed and p.in_vehicle == 0 \
		and v.alive and v.team == p.team and dist <= enter_range

func seat_count() -> int:
	return seats.size()

func free_seat(hint: int) -> int:
	if hint >= 0 and hint < seats.size() and int(seats[hint]) == 0:
		return hint
	for s in seats.size():
		if int(seats[s]) == 0:
			return s
	return -1

func seat_world(seat: int) -> Vector3:
	return pos + rotate_yaw(seat_offsets[seat], heading)

func turret_muzzle() -> Vector3:
	return pos + Vector3(0.0, turret_offset.y, 0.0)

## One authoritative integration step. cmd: {move_y=throttle [-1,1], move_x=steer [-1,1]}.
## Pure kinematic + deterministic; ground floor + world bounds here, platform-floor + structure
## collision applied by SimLoop.step_vehicles (it owns the geometry arrays).
func step(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF) -> void:
	if not alive:
		return
	var throttle := clampf(float(cmd.get("move_y", 0.0)), -1.0, 1.0)
	var steer := clampf(float(cmd.get("move_x", 0.0)), -1.0, 1.0)

	speed += throttle * accel * dt
	speed = clampf(speed, -reverse_speed, max_speed)
	if absf(throttle) < 0.01:
		var d := drag * dt
		if speed > 0.0: speed = maxf(0.0, speed - d)
		else: speed = minf(0.0, speed + d)

	heading += steer * turn_rate * dt * turn_factor(speed, max_speed)

	var fwd := Vector3(sin(heading), 0.0, cos(heading))
	velocity = Vector3(fwd.x * speed, velocity.y - GRAVITY * dt, fwd.z * speed)
	pos += velocity * dt
	if pos.y <= 0.0:
		pos.y = 0.0; velocity.y = 0.0
	pos.x = clampf(pos.x, -world_half, world_half)
	pos.z = clampf(pos.z, -world_half, world_half)

## Occupant pawn ids currently seated (excludes empty seats). Order = seat order.
func occupant_ids() -> Array:
	var out: Array = []
	for occ in seats:
		if int(occ) != 0: out.append(int(occ))
	return out

## Mark the vehicle destroyed at `tick`: clears seats and schedules respawn. The server is
## responsible for killing the (already captured) occupants and broadcasting the event.
func mark_destroyed(tick: int) -> void:
	alive = false
	respawn_tick = tick + respawn_ticks
	speed = 0.0
	velocity = Vector3.ZERO
	for i in seats.size():
		seats[i] = 0

## Respawn at the original spawn pos with full hull.
func respawn() -> void:
	pos = spawn_pos
	hp = max_hp
	alive = true
	speed = 0.0
	velocity = Vector3.ZERO
	respawn_tick = 0

func to_state() -> VehicleState:
	var e := VehicleState.new()
	e.pos = pos
	e.heading = heading
	e.turret_yaw = turret_yaw
	e.hp = hp
	e.type = type
	e.seats = seats.duplicate()
	return e
