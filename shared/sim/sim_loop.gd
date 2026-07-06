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
var terrain: TerrainGrid = null   # optional heightmap; folded into floor + horizontal resolution
var ladders: Array = []   # [{bottom:Vector3, top:Vector3, radius:float}]
var platforms: Array = [] # [{min:Vector3, max:Vector3}] walkable surfaces

func step(inputs: Dictionary, world_half: float = Pawn.WORLD_HALF) -> void:
	for id in world.pawns:
		var p: Pawn = world.pawns[id]
		if not p.alive:
			continue
		var prev := p.pos
		var prev_stance: int = p.stance
		var prev_grounded: bool = p.grounded
		var cmd: Dictionary = inputs.get(id, {})
		p.terrain = terrain
		p.step(DT, cmd, world_half)
		if p.in_vehicle != 0:
			pass   # seat-slaved by step_vehicles — no ground collision/platform/ladder/vault while seated
		elif p.climbing:
			_step_climb(p, cmd)
		elif p.vaulting:
			p.pos = Vault.advance(p)
			if not p.vaulting:
				_apply_platform_floor(p)
		else:
			_step_normal(p, prev, cmd, prev_grounded)
		if p.stance != prev_stance:
			p.last_stance_change_tick = tick
		_account_fall(p, prev_grounded)
	tick += 1

func _step_climb(p: Pawn, cmd: Dictionary) -> void:
	var ladder := Ladder.capture(ladders, p.pos)
	if ladder.is_empty():
		p.climbing = false
		return
	var move_y: float = cmd.get("move_y", 0.0)
	var move_x: float = cmd.get("move_x", 0.0)
	# Vertical climb pins (x,z) to the ladder line; move_y drives the y.
	var climbed := Ladder.climb_step(ladder, p.pos, move_y, DT)
	# Strafe off (BattleBit ladder dismount): lateral input (world-X; the town ladders are yaw 0)
	# slides the pawn off the line at walk speed. Once it clears the capture volume the climb is
	# released and normal movement (gravity/step) carries the pawn away.
	if absf(move_x) > 0.1:
		var speed: float = Stance.speed(p.stance) * Armor.speed_mult(p.armor_class)
		climbed.x = p.pos.x + move_x * speed * DT
	p.pos = climbed
	if absf(move_x) > 0.1 and Ladder.capture(ladders, p.pos).is_empty():
		p.climbing = false   # strafed out of the volume -> dismount into normal movement
		return
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

func _step_normal(p: Pawn, prev: Vector3, cmd: Dictionary, prev_grounded: bool) -> void:
	var intended := Terrain.resolve_movement(terrain, prev, p.pos)
	if structures != null:
		var resolved: Vector3 = structures.resolve_movement(prev, intended)
		if resolved != intended:
			# Blocked. Vault it if it is a low blocker and we are standing + moving.
			var top: float = structures.ground_blocker_top(intended)
			var flat := Vector3(intended.x - prev.x, 0.0, intended.z - prev.z)
			var moving := flat.length() > MIN_MOVE_LEN
			var jump_pressed := bool(int(cmd.get("buttons", 0)) & InputCommand.BTN_JUMP)
			# Manual vault (BattleBit): a human (auto_vault=false) must press jump to mount a low blocker;
			# bots keep vaulting on contact so navigation and the fleet gate's vaults>=1 hold. Gate on
			# prev_grounded, not p.grounded: a jump THIS tick already cleared p.grounded in Pawn.step(),
			# and a truthful grounded also keeps a FALLING pawn (prev_grounded=false) from vaulting a
			# 2 m wall whose upper band its feet happen to pass.
			if prev_grounded and (p.auto_vault or jump_pressed) and Vault.can_vault(top, p.stance, moving):
				var land := _vault_landing(prev, flat.normalized())
				if bool(land["ok"]):
					Vault.begin_at(p, prev, land["to"])
					p.pos = prev
					# If a JUMP press triggered this vault, undo the jump impulse/cost Pawn.step() just
					# applied so the pawn neither launches upward when the arc completes nor pays stamina
					# (vaulting is free, as the old auto-vault was). Auto-vault (bots) never jumped, so
					# this leaves their state untouched.
					if jump_pressed and not p.grounded:
						p.velocity.y = 0.0
						p.grounded = true
						p.stamina = minf(Pawn.STAMINA_MAX, p.stamina + Pawn.JUMP_COST)
					return
				# No clear ground to land on (e.g. a wall right behind the low blocker) -> refuse the
				# vault and stay blocked, so the arc never teleports the pawn into/through the wall.
			p.pos = resolved
		else:
			p.pos = resolved
	else:
		p.pos = intended
	_apply_platform_floor(p)
	# Ladder engage (after movement, so a pawn that walked into the volume this tick climbs next tick).
	# Downed pawns crawl — they don't grab ladders (3 m/s climb would triple their crawl speed).
	if not p.climbing and not p.is_downed:
		var ladder := Ladder.capture(ladders, p.pos)
		if Ladder.should_engage(ladder, p.pos, cmd.get("move_y", 0.0)):
			p.climbing = true

## First collision-safe vault landing along `dir` from `from`, on the vault's floor plane. The scan
## walks outward, requires actually CROSSING the blocked band first (so a clear point between the
## pawn and the blocker face never "lands" short of the wall), stops dead at the first tall
## (non-vaultable) blocker, and accepts the first clear-standing point past the band (+1 step of
## clearance when that is also clear). The scan range covers the worst case: up to ~0.32 m sprint
## stopping gap before the cell face + a 2.83 m diagonal chord through one 2 m cell + clearance —
## the old fixed 1.8..2.3 m window silently refused head-on sprints and any approach >~30° off
## perpendicular, leaving the pawn stuck pushing against a plain vaultable box.
## {ok:false} when nothing qualifies (e.g. a wall directly behind the low blocker) -> refuse the vault.
const _VAULT_SCAN_STEP := 0.25
const _VAULT_MAX_SCAN := 3.6   # m; stopping gap + one-cell diagonal chord + landing clearance
func _vault_landing(from: Vector3, dir: Vector3) -> Dictionary:
	var crossed := false   # have we sampled inside the blocked (low-blocker) band yet?
	var d := _VAULT_SCAN_STEP
	while d <= _VAULT_MAX_SCAN + 0.001:
		var cand := Vector3(from.x + dir.x * d, from.y, from.z + dir.z * d)
		if structures.is_tall_blocker(cand):
			return {"ok": false}   # a wall in/behind the vault path — refuse
		if not structures.stands_clear(cand):
			crossed = true
		elif crossed:
			# First clear ground past the band. Land one step farther when that's also clear, so the
			# pawn doesn't come to rest kissing the blocker's far face.
			var land_d := d + _VAULT_SCAN_STEP
			var land := Vector3(from.x + dir.x * land_d, from.y, from.z + dir.z * land_d)
			if land_d > _VAULT_MAX_SCAN or structures.is_tall_blocker(land) or not structures.stands_clear(land):
				land = cand
			return {"ok": true, "to": land}
		d += _VAULT_SCAN_STEP
	return {"ok": false}

func _apply_platform_floor(p: Pawn) -> void:
	# terr is the ground baseline (0.0 on flat maps). It replaces the old implicit y=0 in the grounded
	# tests below so a sub-zero valley is walkable (M15) without changing flat-map behaviour.
	var terr := Terrain.height_at(terrain, p.pos.x, p.pos.z)
	var floor_y := Ladder.platform_floor(platforms, p.pos.x, p.pos.z, p.pos.y)
	floor_y = maxf(floor_y, terr)
	if structures != null:
		floor_y = maxf(floor_y, structures.floor_height_at(p.pos.x, p.pos.z, p.pos.y))
	if p.pos.y < floor_y:
		p.pos.y = floor_y
		p.velocity.y = 0.0
		p.grounded = true
	elif p.pos.y <= floor_y + Ladder.ANCHOR_EPS and floor_y > terr:
		p.grounded = true
	elif p.pos.y > floor_y + Ladder.ANCHOR_EPS:
		# Airborne: above the ground plane AND above any platform/structure floor. Without clearing
		# this, a pawn that WALKED off a roof kept grounded=true for the whole fall — no false->true
		# landing edge (zero fall damage from any height) and a free mid-air jump (BTN_JUMP gate).
		p.grounded = false

## Track airborne peak height and emit landed_fall (distance) on the tick a pawn lands. Climbing pawns
## are anchored to the ladder line (no fall). Server reads landed_fall to apply fall damage.
func _account_fall(p: Pawn, prev_grounded: bool) -> void:
	p.landed_fall = 0.0
	if p.climbing:
		p.fall_peak_y = p.pos.y
		return
	if p.grounded:
		if not prev_grounded:
			p.landed_fall = maxf(0.0, p.fall_peak_y - p.pos.y)
		p.fall_peak_y = p.pos.y
	else:
		p.fall_peak_y = maxf(p.fall_peak_y, p.pos.y)

## Integrate vehicles (server authority). vinputs: vid -> driver command dict. Applies
## structure-stop + platform-floor (SimLoop owns the geometry arrays), then slaves seated
## occupants to their seat transform and feeds the gunner's look into the turret. See vehicles spec.
func step_vehicles(vinputs: Dictionary, world_half: float = Vehicle.WORLD_HALF) -> void:
	for vid in world.vehicles:
		var v: Vehicle = world.vehicles[vid]
		if not v.alive:
			continue
		var prev := v.pos
		v.terrain = terrain
		v.step(DT, vinputs.get(vid, {}), world_half)
		# Terrain slope-block: revert an advance that climbed a too-steep face.
		var t_res := Terrain.resolve_movement(terrain, prev, v.pos)
		if t_res != v.pos:
			v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		if structures != null:
			var seg := v.pos - prev
			var seg_len := seg.length()
			if seg_len > 0.0001:
				var m: Dictionary = structures.march(prev, seg / seg_len, seg_len)
				# id 0 = a terrain hit (M15); vehicle-vs-terrain is handled by the slope-block (above) +
				# floor clamp (below). Only a real piece (id != 0) stops the hull — else march's terrain
				# occlusion would freeze the vehicle on its own ground column.
				if bool(m["hit"]) and int(m["id"]) != 0:
					v.pos = prev; v.speed = 0.0; v.velocity = Vector3.ZERO
		var floor_y := Ladder.platform_floor(platforms, v.pos.x, v.pos.z, v.pos.y)
		floor_y = maxf(floor_y, Terrain.height_at(terrain, v.pos.x, v.pos.z))
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
