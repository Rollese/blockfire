class_name Pawn
extends RefCounted
## Kinematic player pawn. Authoritative on the server; predicted on the client.
## step() takes a command dict {move_x,move_y,yaw,pitch,buttons}; missing keys default,
## so partial dicts are tolerated. Movement is world-space planar + vertical jump/gravity.

const Terrain := preload("res://shared/sim/terrain.gd")

const SPRINT_MULT := 1.6
const GRAVITY := 14.0
const JUMP_V0 := 4.5
const JUMP_COST := 10.0
const SPRINT_DRAIN := 15.0
const STAMINA_REGEN := 12.0
const STAMINA_REGEN_DELAY := 1.0
const STAMINA_MAX := 100.0
const SPRINT_RESUME := 20.0   # once stamina bottoms out, can't sprint again until it regens past this (BattleBit hysteresis)
const STIM_SPEED_MULT := 1.15   # M19: Combat Stim move-speed multiplier
const STIM_STAMINA_MULT := 2.0  # M19: Combat Stim stamina-regen multiplier
const WORLD_HALF := 1000.0
const MAX_PITCH := 1.4835  # ~85 degrees
const PRONE_TRANSITION_TICKS := 10  # fire blocked for this many ticks after entering prone (drop-shoot fix)

var id: int
var pos: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var yaw: float = 0.0
var pitch: float = 0.0
var stance: int = 0
var lean: int = 0
var stamina: float = STAMINA_MAX
var grounded: bool = true
var terrain: TerrainGrid = null   # optional heightmap; null = flat (y ground plane at 0)
var health: int = 100
var alive: bool = true
var team: int = 0
var squad: int = 0
var _regen_cooldown: float = 0.0
var _sprint_locked: bool = false   # true after stamina hit 0 while sprinting; cleared once stamina >= SPRINT_RESUME
var is_downed: bool = false
var down_count: int = 0            # times downed THIS life (reset on spawn); drives the halving window
var bleed_health: int = 0          # 0 at down, drains to bleed_floor (= -Revive.bleedout_window)
var bleed_floor: int = 0           # per-down bleed-out threshold, set when the pawn goes down
var bleed_halted: bool = false     # RESERVED/inert: kept for the SELF_STATE wire; downed self-bandage removed 2026-07-03
var bandage_count: int = Revive.BANDAGE_COUNT   # bandage pouch: spent by standing-bandage + revive (M16)
# M16 standing bleed (distinct from the DOWNED halving-bleedout fields above): a below-threshold
# bullet/blast hit sets `bleeding`, which drains the standing `health` pool until bandaged or bled out.
var bleeding: bool = false         # standing bleed active
var bleed_by: int = 0              # attacker id credited if this bleed downs the pawn (mirrors downed_by)
var bleed_weapon: int = 0          # weapon id of the bleed source, for the down/kill recap
var combat_until_tick: int = 0     # "in combat" until this tick (set when damaged); blocks being a squad-spawn anchor
var last_stance_change_tick: int = -1000   # set by SimLoop when stance changes; drop-shoot gate
var climbing: bool = false
var vaulting: bool = false
var auto_vault: bool = true   # bots vault a low blocker on contact; humans (set false) must press jump (BattleBit)
var fall_peak_y: float = 0.0   # highest y reached since leaving the ground (for fall damage)
var landed_fall: float = 0.0   # transient: fall distance on the tick a landing occurred, else 0 (not replicated)
var vault_tick: int = 0
var vault_from: Vector3 = Vector3.ZERO
var vault_to: Vector3 = Vector3.ZERO
var in_vehicle: int = 0    # vehicle id the pawn is seated in (0 = on foot)
var seat: int = -1         # seat index when in_vehicle != 0
var mounted_nest: int = 0   # emplacement id the pawn is manning (0 = not on a nest); distinct from in_vehicle
var armor_class: int = Armor.LIGHT   # M5.5-P2: body-damage + move-speed tier (set from class at spawn)
var suppression: float = 0.0         # M5.5-P2: 0..1 incoming-fire scalar; widens own spread, decays per tick
var blind_until_tick: int = 0        # M5.5-P3: flashbang white-out persists until this tick (0 = not blinded)
var stim_until_tick: int = 0         # M19: Combat Stim buff active until this tick (server-set; mirrors blind_until_tick)

func _init(p_id: int = 0) -> void:
	id = p_id

func step(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF) -> void:
	yaw = cmd.get("yaw", yaw)
	pitch = clampf(cmd.get("pitch", pitch), -MAX_PITCH, MAX_PITCH)
	if in_vehicle != 0 or mounted_nest != 0:
		return   # position driven by SimLoop seat slaving / emplacement slaving; look already applied above
	if is_downed:
		_step_downed(dt, cmd, world_half)
		return
	if climbing or vaulting:
		return   # position is driven by SimLoop (ladder line / vault arc); look already applied above
	var buttons: int = cmd.get("buttons", 0)

	# stance
	if buttons & InputCommand.BTN_PRONE:
		stance = Stance.PRONE
	elif buttons & InputCommand.BTN_CROUCH:
		stance = Stance.CROUCH
	else:
		stance = Stance.STAND
	# lean
	if buttons & InputCommand.BTN_LEAN_L:
		lean = Stance.LEAN_LEFT
	elif buttons & InputCommand.BTN_LEAN_R:
		lean = Stance.LEAN_RIGHT
	else:
		lean = Stance.LEAN_NONE

	var move := Vector3(cmd.get("move_x", 0.0), 0.0, cmd.get("move_y", 0.0))
	if move.length() > 1.0:
		move = move.normalized()
	var has_move := move.length() > 0.01

	var shielded := bool(cmd.get("shielded", false))
	var sprinting := bool(buttons & InputCommand.BTN_SPRINT) and stance == Stance.STAND and stamina > 0.0 and has_move and not _sprint_locked and not shielded
	var stimmed := bool(cmd.get("stimmed", false))
	var speed := Stance.speed(stance) * (SPRINT_MULT if sprinting else 1.0) * Armor.speed_mult(armor_class) * (STIM_SPEED_MULT if stimmed else 1.0) * (RiotShield.SHIELD_SPEED_MULT if shielded else 1.0)
	velocity.x = move.x * speed
	velocity.z = move.z * speed

	# jump
	if (buttons & InputCommand.BTN_JUMP) and grounded and stamina >= JUMP_COST:
		velocity.y = JUMP_V0
		stamina -= JUMP_COST
		_regen_cooldown = STAMINA_REGEN_DELAY
		grounded = false

	# gravity + integrate
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	var ground := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= ground:
		pos.y = ground
		velocity.y = 0.0
		grounded = true

	# stamina
	if sprinting:
		stamina -= SPRINT_DRAIN * dt
		_regen_cooldown = STAMINA_REGEN_DELAY
	else:
		_regen_cooldown = maxf(0.0, _regen_cooldown - dt)
		if _regen_cooldown <= 0.0:
			stamina += STAMINA_REGEN * (STIM_STAMINA_MULT if stimmed else 1.0) * dt
	stamina = clampf(stamina, 0.0, STAMINA_MAX)
	# BattleBit sprint-lockout hysteresis: once stamina bottoms out you cannot sprint again until it
	# regens past SPRINT_RESUME. This removes the pathological 1-tick empty-sprint burst that ran at
	# ~1 Hz — and with it the wire-rounding desync (server stamina 0.4 rounded to 0, so the client
	# could never reproduce the burst tick and rubber-banded backward once per second). Replicated +
	# reconciled like _regen_cooldown so the client predicts the identical rule across a reconcile.
	if stamina <= 0.0:
		_sprint_locked = true
	elif stamina >= SPRINT_RESUME:
		_sprint_locked = false

	pos.x = clampf(pos.x, -world_half, world_half)
	pos.z = clampf(pos.z, -world_half, world_half)

func _step_downed(dt: float, cmd: Dictionary, world_half: float = WORLD_HALF) -> void:
	# Crawl-only: forced prone, no lean, no sprint/jump, gravity still applies.
	stance = Stance.PRONE
	lean = Stance.LEAN_NONE
	var move := Vector3(cmd.get("move_x", 0.0), 0.0, cmd.get("move_y", 0.0))
	if move.length() > 1.0:
		move = move.normalized()
	velocity.x = move.x * Revive.DOWNED_CRAWL_SPEED
	velocity.z = move.z * Revive.DOWNED_CRAWL_SPEED
	velocity.y -= GRAVITY * dt
	pos += velocity * dt
	var ground := Terrain.height_at(terrain, pos.x, pos.z)
	if pos.y <= ground:
		pos.y = ground
		velocity.y = 0.0
		grounded = true
	pos.x = clampf(pos.x, -world_half, world_half)
	pos.z = clampf(pos.z, -world_half, world_half)

func eye_position() -> Vector3:
	return pos + Vector3(0.0, Stance.eye_height(stance), 0.0)

## M5.5-P3: true while a flashbang white-out is still active at `tick`.
func is_blinded(tick: int) -> bool:
	return tick < blind_until_tick

## M19-P5: true when a shield-up pawn's primary fire is locked out (they're holding the shield).
static func fire_suppressed_by_shield(buttons: int, shielded: bool) -> bool:
	return shielded and (buttons & InputCommand.BTN_FIRE) != 0

func to_state() -> EntityState:
	var e := EntityState.new()
	e.pos = pos
	e.yaw = yaw
	e.pitch = pitch
	e.stance = stance
	e.lean = lean
	e.team = team
	e.squad = squad
	e.alive = alive
	e.health = health
	e.is_downed = is_downed
	e.climbing = climbing
	e.armor_class = armor_class
	return e
