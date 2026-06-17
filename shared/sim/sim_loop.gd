class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. Same code runs on server (authority) and
## client (prediction). inputs: Dictionary[int id -> command dict]. See AGENTS.md §7.
## P3: drives ladder climbing, auto-vaulting, platform floor, and records stance-change ticks.
## Geometry arrays (ladders/platforms) are set by the server; empty during client prediction.

const DT := 1.0 / 30.0   # 30 Hz
const MIN_MOVE_LEN := 0.001   # m; below this a pawn is treated as stationary (no vault trigger)

var tick: int = 0
var world := World.new()
var structures: StructureStore = null     # optional StructureStore; resolves movement collision + vault blockers
var ladders: Array = []   # [{bottom:Vector3, top:Vector3, radius:float}]
var platforms: Array = [] # [{min:Vector3, max:Vector3}] walkable surfaces

func step(inputs: Dictionary, world_half: float = Pawn.WORLD_HALF) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		var prev := p.pos
		var prev_stance: int = p.stance
		var cmd: Dictionary = inputs.get(id, {})
		p.step(DT, cmd, world_half)
		if p.climbing:
			_step_climb(p, cmd)
		elif p.vaulting:
			p.pos = Vault.advance(p)
			if not p.vaulting:
				_apply_platform_floor(p)
		else:
			_step_normal(p, prev, cmd)
		if p.stance != prev_stance:
			p.last_stance_change_tick = tick
	tick += 1

func _step_climb(p: Pawn, cmd: Dictionary) -> void:
	var ladder := Ladder.capture(ladders, p.pos)
	if ladder.is_empty():
		p.climbing = false
		return
	var move_y: float = cmd.get("move_y", 0.0)
	p.pos = Ladder.climb_step(ladder, p.pos, move_y, DT)
	var top: Vector3 = ladder["top"]
	var bottom: Vector3 = ladder["bottom"]
	if p.pos.y >= top.y - Ladder.ANCHOR_EPS:
		p.pos.y = top.y          # reached top: dismount onto the platform
		p.velocity.y = 0.0
		p.grounded = true
		p.climbing = false
	elif p.pos.y <= bottom.y + Ladder.ANCHOR_EPS and move_y < 0.0:
		p.pos.y = bottom.y       # reached bottom while descending: dismount to ground
		p.velocity.y = 0.0
		p.grounded = true
		p.climbing = false

func _step_normal(p: Pawn, prev: Vector3, cmd: Dictionary) -> void:
	var intended := p.pos
	if structures != null:
		var resolved: Vector3 = structures.resolve_movement(prev, intended)
		if resolved != intended:
			# Blocked. Vault it if it is a low blocker and we are standing + moving.
			var top: float = structures.ground_blocker_top(intended)
			var flat := Vector3(intended.x - prev.x, 0.0, intended.z - prev.z)
			var moving := flat.length() > MIN_MOVE_LEN
			if Vault.can_vault(top, p.stance, moving):
				Vault.begin(p, prev, flat.normalized())
				p.pos = prev
				return
			p.pos = resolved
		else:
			p.pos = resolved
	_apply_platform_floor(p)
	# Ladder engage (after movement, so a pawn that walked into the volume this tick climbs next tick).
	if not p.climbing:
		var ladder := Ladder.capture(ladders, p.pos)
		if Ladder.should_engage(ladder, p.pos, cmd.get("move_y", 0.0)):
			p.climbing = true

func _apply_platform_floor(p: Pawn) -> void:
	var floor_y := Ladder.platform_floor(platforms, p.pos.x, p.pos.z, p.pos.y)
	if p.pos.y < floor_y:
		p.pos.y = floor_y
		p.velocity.y = 0.0
		p.grounded = true
	elif p.pos.y <= floor_y + Ladder.ANCHOR_EPS and floor_y > 0.0:
		p.grounded = true

## Integrate vehicles (server authority). vinputs: vid -> driver command dict. Applies
## structure-stop + platform-floor (SimLoop owns the geometry arrays), then slaves seated
## occupants to their seat transform and feeds the gunner's look into the turret. See vehicles spec.
func step_vehicles(vinputs: Dictionary, world_half: float = Vehicle.WORLD_HALF) -> void:
	for vid in world.vehicles:
		var v: Vehicle = world.vehicles[vid]
		if not v.alive:
			continue
		var prev := v.pos
		v.step(DT, vinputs.get(vid, {}), world_half)
		if structures != null:
			var seg := v.pos - prev
			var seg_len := seg.length()
			if seg_len > 0.0001:
				var m: Dictionary = structures.march(prev, seg / seg_len, seg_len)
				if bool(m["hit"]):
					v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		var floor_y := Ladder.platform_floor(platforms, v.pos.x, v.pos.z, v.pos.y)
		if v.pos.y < floor_y:
			v.pos.y = floor_y; v.velocity.y = 0.0
		for seat in v.seats.size():
			var occ: int = int(v.seats[seat])
			if occ == 0:
				continue
			var p: Pawn = world.get_pawn(occ)
			if p == null:
				continue
			p.pos = v.seat_world(seat)
			if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER:
				v.turret_yaw = p.yaw
