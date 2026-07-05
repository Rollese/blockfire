class_name Prediction
extends RefCounted
## Client-side prediction + reconciliation for the local pawn. Drives the SAME SimLoop the server runs
## (movement + collision + auto-vault + ladder climb), so the predicted pawn behaves identically to the
## authority — no divergence to rubber-band. Without the full loop the client would, e.g., stop at a low
## blocker the server vaults over and get yanked forward (the sprint choppiness).

var _loop := SimLoop.new()
var predicted: Pawn               # the local pawn, living inside _loop.world
var pending: Array = []           # [{tick, cmd}] or [{tick, move_x, move_y, yaw}], ascending tick

var world_half: float = Pawn.WORLD_HALF   # set from the map so prediction clamps like the server

# The client-mirror StructureStore (set by client_main); forwarded to the loop so prediction collides.
var structures:
	set(v):
		_loop.structures = v
	get:
		return _loop.structures

func _init() -> void:
	predicted = Pawn.new(0)
	predicted.auto_vault = false   # the local pawn is always a human: vault only on jump (matches the server)
	_loop.world.pawns[0] = predicted

## Ladders/platforms from the adopted map, so climb + platform-floor predict like the server.
func set_geometry(ladders: Array, platforms: Array) -> void:
	_loop.ladders = ladders
	_loop.platforms = platforms

## One full simulation step for the local pawn (movement + collision + vault + climb), identical to
## the server's SimLoop.step.
func _advance(cmd: Dictionary) -> void:
	_loop.step({0: cmd}, world_half)

func record_input(client_tick: int, move_x: float, move_y: float, yaw: float) -> void:
	_advance({"move_x": move_x, "move_y": move_y, "yaw": yaw})
	pending.append({"tick": client_tick, "move_x": move_x, "move_y": move_y, "yaw": yaw})

func reconcile(auth_pos: Vector3, auth_yaw: float, last_input_tick: int) -> void:
	var kept := []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	for inp in pending:
		_advance({"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})

func record_cmd(client_tick: int, cmd: Dictionary) -> void:
	_advance(cmd)
	pending.append({"tick": client_tick, "cmd": cmd})

func reconcile_full(auth_pos: Vector3, auth_yaw: float, auth_pitch: float, last_input_tick: int,
		auth_stamina: float = Pawn.STAMINA_MAX, auth_vel_y: float = 0.0, auth_grounded: bool = true,
		auth_vaulting: bool = false, auth_vault_tick: int = 0, auth_regen_cooldown: float = 0.0,
		auth_sprint_locked: bool = false) -> void:
	var kept: Array = []
	for inp in pending:
		if inp["tick"] > last_input_tick:
			kept.append(inp)
	pending = kept
	predicted.pos = auth_pos
	predicted.yaw = auth_yaw
	predicted.pitch = auth_pitch
	# Reset stamina to authority BEFORE replaying pending inputs. Without this, each snapshot replayed
	# every pending input and re-drained stamina (~RTT x too fast), so predicted sprint kept hitting
	# empty and dropping to walk speed while the server sprinted on -> forward rubber-band in the open.
	predicted.stamina = auth_stamina
	# ...and the regen cooldown alongside it (C6). Reconciling stamina but NOT its cooldown let the two
	# drift, so predicted stamina diverged exactly at the sprint-empty and jump-cost boundaries — the
	# jump apex snapped and sprint flickered ~1 Hz once stamina bottomed out. Replaying the pending
	# inputs re-derives the cooldown from here identically to the server.
	predicted._regen_cooldown = auth_regen_cooldown
	# ...and the sprint-lockout flag (empty-sprint hysteresis). During stamina recovery neither the
	# stamina==0 nor the >=SPRINT_RESUME branch fires, so the flag never recomputes on replay — a stale
	# predicted lock would mis-predict sprint vs walk for the whole recovery window. Pin it to authority.
	predicted._sprint_locked = auth_sprint_locked
	# Likewise reset the vertical velocity + grounded flag to authority before replay. Without this the
	# jump replay integrated gravity from a stale velocity.y and the predicted arc snapped back mid-jump.
	predicted.velocity.y = auth_vel_y
	predicted.grounded = auth_grounded
	# Vault state, same bug class: while vaulting, SimLoop drives pos from the stored arc — a stale
	# local arc would override the authoritative position, and each replayed input advanced vault_tick
	# again on top of the per-tick advance (the arc finished (1+pending)x too fast and stuttered).
	# Both sides start the vault from the same input + geometry, so the predicted vault_from/vault_to
	# match the server's — only the PROGRESS needs re-syncing. If the server vaults and we never
	# predicted one (missed trigger), there is no local arc to resume: stay non-vaulting and let the
	# per-snapshot authoritative positions carry the camera over (self-heals at arc end).
	if auth_vaulting and predicted.vaulting:
		predicted.vault_tick = auth_vault_tick
	else:
		predicted.vaulting = false
	for inp in pending:
		if inp.has("cmd"):
			_advance(inp["cmd"])
		else:
			_advance({"move_x": inp["move_x"], "move_y": inp["move_y"], "yaw": inp["yaw"]})
