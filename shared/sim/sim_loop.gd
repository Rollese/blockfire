class_name SimLoop
extends RefCounted
## Fixed-timestep authoritative simulation. Same code runs on server (authority) and
## client (prediction). inputs: Dictionary[int id -> command dict]. See AGENTS.md §7.
## P3: drives ladder climbing, auto-vaulting, platform floor, and records stance-change ticks.
## Geometry arrays (ladders/platforms) are set by the server; empty during client prediction.

const DT := 1.0 / 30.0   # 30 Hz

var tick: int = 0
var world := World.new()
var structures = null     # optional StructureStore; resolves movement collision + vault blockers
var ladders: Array = []   # [{bottom:Vector3, top:Vector3, radius:float}]
var platforms: Array = [] # [{min:Vector3, max:Vector3}] walkable surfaces

func step(inputs: Dictionary) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		var prev := p.pos
		var prev_stance: int = p.stance
		p.step(DT, inputs.get(id, {}))
		var cmd: Dictionary = inputs.get(id, {})
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
		p.grounded = true
		p.climbing = false
	elif p.pos.y <= bottom.y + Ladder.ANCHOR_EPS and move_y < 0.0:
		p.pos.y = bottom.y       # reached bottom while descending: dismount to ground
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
			var moving := flat.length() > 0.001
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
