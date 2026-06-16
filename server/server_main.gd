extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), Conquest mode (capture points, tickets, win), squads, deploy/respawn.
## See docs/specs/m3-conquest-squads.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0
const MAX_HISTORY := 32
const SNAPSHOT_STRIDE := 2   # send each client a snapshot every Nth tick (round-robin by id),
                             # so per-tick encode cost is ~clients/STRIDE instead of O(clients).
                             # Client-side interpolation smooths the lower send rate (30/STRIDE Hz).
const MAX_SNAPSHOT_ENTITIES := 32   # over this many entities in interest range, the relevance cull
                                    # runs: ALL teammates are kept (friendlies are never hidden — no
                                    # wallhack concern, and you must see downed squadmates to revive)
                                    # and only enemies are capped (see _build_interest).
const MAX_ENEMY_SNAPSHOT := 24      # max enemies per snapshot (nearest-first) once the cull runs —
                                    # the only set with a wallhack concern; bounds the O(N^2) peak.
                                    # Total snapshot ≈ (teammates in range) + ≤24 enemies.
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray
const FIRE_RANGE_MARGIN := 20.0    # grid broad-phase slack for lag-comp movement
const MAP_PATH := "res://maps/conquest_proving_grounds.json"
const MATCH_STATE_INTERVAL := 15   # ticks between match-state broadcasts (2 Hz)
const MATCH_END_DRAIN_TICKS := 60  # keep running ~2s after a win, then exit
const MAX_STRUCTURE_DELTAS_PER_TICK := 64   # graceful degradation: cap delta SENDS/tick
const GRENADE_FUSE_TICKS := 45        # 1.5s @30Hz
const GRENADE_COOLDOWN_TICKS := 300   # 10s between a player's throws (shared frag/smoke)
const BLAST_PAWN_RADIUS := 6.0        # m, sphere (current positions, FF-off)
const BLAST_STRUCT_RADIUS := 4.0      # m (~2 build cells)
const GRENADE_DAMAGE_PAWN := 100      # frag pawn splash at centre, linear falloff
const GRENADE_DAMAGE_STRUCT := 200    # frag structure splash at centre, linear falloff
const SMOKE_DURATION_TICKS := 150     # 5s @30Hz — smoke zone lifetime
const SMOKE_RADIUS := 6.0             # m — smoke zone radius (matches blast radius)
const PIECES_PATH := "res://pieces/fortifications.json"
const GADGETS_PATH := "res://data/gadgets.json"
const ATTACHMENTS_PATH := "res://data/attachments.json"

var _net: NetHost
var _port := 27015
var _start_tickets := -1
var _time_limit := -1.0
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _map: MapDef
var _conquest: ConquestState
var _squads := SquadManager.new()
var _catalog: PieceCatalog
var _store: StructureStore
var _gadgets: Gadget
var _attachments: Attachment
var _next_struct_id := 1
var _next_id := 1
var _tele_accum := 0.0
# Per-phase tick profiling (mean usec/tick over the telemetry window).
var _phase_us := {"poll": 0, "move": 0, "lag": 0, "interest": 0, "fire": 0, "respawn": 0, "conquest": 0, "match": 0, "snap": 0}
var _phase_ticks := 0
var _team_counts := {0: 0, 1: 0}
var _positions := {}               # id -> Vector3, rebuilt each tick before fires
var _prev_move_state: Dictionary = {}   # id -> {"c":bool,"v":bool} for climb/vault edge counting

var _reviving := {}            # reviver_id -> target_id, set per tick by REVIVE_ACTION(active)
var _revive_ticks := {}        # target_id -> accumulated revive ticks
var _revives := 0              # completed revives this window
var _climbs := 0              # climb-mode entries this window
var _vaults := 0              # vault completions this window
var _drop_shoot_blocked := 0  # shots rejected by the prone-transition gate this window

var _kills := 0
var _shots := 0
var _hits := 0
var _downed := 0              # pawns sent to DOWNED this window
var _bleedouts := 0           # downed pawns that bled out (true deaths) this window
var _rewind_clamped := 0
var _cap_events := 0          # per-telemetry-window (reset each second)
var _cap_events_total := 0    # cumulative over the match (for the match-end summary)
var _builds := 0
var _removes := 0
var _shots_blocked := 0
var _pen := 0                 # bullet penetrations through a piece this window
var _dmg := 0                 # damage events applied this window
var _destroyed := 0           # pieces removed by damage/blast this window
var _nades := 0               # frag detonations this window
var _splash_kills := 0        # pawn deaths from blasts this window
var _smokes := 0              # smoke zones deployed this window
var _rockets_det := 0         # RPG rockets detonated this window
var _c4_det := 0              # C4 detonations (per detonate action) this window
var _mine_trips := 0          # claymore/mine detonations this window
var _heals := 0          # active+bag HP-dispensing events this window
var _ammo_gives := 0     # active+bag ammo-resupply events this window
var _bags_thrown := 0    # bags deployed this window
var _bags_exhausted := 0 # bags that hit pool 0 and vanished this window
var _rstruct := 0             # structures hit by rockets this window
var _pending_removes: Array = []   # [{id, cell}] removes awaiting send (degradation queue)
var _dmg_touched := {}             # id -> true: pieces damaged (alive) this tick, for bucket diff
var _last_bucket := {}             # id -> last SENT bucket (missing => pristine bucket 3)
var _grenades: Array = []     # [{owner, team, type, pos, vel, detonate_tick}] — server-side, not replicated
var _rockets: Array = []      # [{owner, team, pos, vel}] — server-side, not replicated
var _mines: Array = []        # [{owner, team, pos, facing, armed_after_tick}]
var _giving: Dictionary = {}   # giver_id -> tick the give began (latched; cleared on STOP/invalid)
var _bags: Array = []          # [{owner, team, kind, pos, pool}]
var _c4: Dictionary = {}      # owner_id -> Array of {pos, cell:Vector3i}
var _smoke_zones: Array = []  # [{pos, radius, expire_tick}] — server-side; M7 LOS culling consumes
var _prev_owners: Array = []
var _match_over_broadcast := false
var _match_end_tick := -1

var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))
	_start_tickets = int(args.get("tickets", -1))
	_time_limit = float(args.get("time-limit", -1.0))

func _ready() -> void:
	_map = MapDef.load_file(MAP_PATH)
	if _map == null:
		push_error("[server] failed to load map %s" % MAP_PATH); get_tree().quit(1); return
	_conquest = ConquestState.new(_map)
	if _start_tickets > 0:
		_conquest.tickets = [float(_start_tickets), float(_start_tickets)]
	if _time_limit > 0.0:
		_conquest.time_limit = _time_limit
	_prev_owners = _owner_snapshot()
	_catalog = PieceCatalog.load_file(PIECES_PATH)
	if _catalog == null:
		push_error("[server] failed to load pieces %s" % PIECES_PATH); get_tree().quit(1); return
	_store = StructureStore.new(_catalog)
	_sim.structures = _store
	_sim.ladders = _map.ladders
	_sim.platforms = _map.platforms
	for pb in _map.prebuilt:
		var ti := _piece_index(String(pb["type"]))
		if ti < 0:
			push_error("[map] prebuilt unknown piece '%s'" % pb["type"]); continue
		var sid := _next_struct_id
		_next_struct_id += 1
		_store.place(sid, ti, pb["cell"], 0, 0)   # owner 0 = world-placed
	_gadgets = Gadget.load_file(GADGETS_PATH)
	if _gadgets == null:
		push_error("[server] failed to load gadgets %s" % GADGETS_PATH); get_tree().quit(1); return
	_attachments = Attachment.load_file(ATTACHMENTS_PATH)
	if _attachments == null:
		push_error("[server] failed to load attachments %s" % ATTACHMENTS_PATH); get_tree().quit(1); return
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d map=%s" % [_port, TICK_RATE, MAX_PLAYERS, _map.name])

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	var t_poll := Time.get_ticks_usec()
	_step_movement()
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		var prev: Dictionary = _prev_move_state.get(id, {"c": false, "v": false})
		if p.climbing and not prev["c"]:
			_climbs += 1
		if p.vaulting and not prev["v"]:
			_vaults += 1
		_prev_move_state[id] = {"c": p.climbing, "v": p.vaulting}
	var t_move := Time.get_ticks_usec()
	_lag.record(_sim.tick, _sim.world)
	var t_lag := Time.get_ticks_usec()
	_build_interest()
	var t_int := Time.get_ticks_usec()
	_resolve_fires()
	var t_fire := Time.get_ticks_usec()
	_step_grenades()
	_step_rockets()
	_step_mines()
	_step_active_give()
	_step_bags()
	_expire_smoke_zones()
	_step_revives()
	_step_downed()
	_handle_respawns()
	var t_resp := Time.get_ticks_usec()
	_conquest.step(SimLoop.DT, _sim.world)
	var t_conq := Time.get_ticks_usec()
	_track_and_broadcast_match_state()
	var t_match := Time.get_ticks_usec()
	_emit_structure_deltas()
	_send_snapshots()
	var t_snap := Time.get_ticks_usec()
	_phase_us["poll"] += t_poll - t0
	_phase_us["move"] += t_move - t_poll
	_phase_us["lag"] += t_lag - t_move
	_phase_us["interest"] += t_int - t_lag
	_phase_us["fire"] += t_fire - t_int
	_phase_us["respawn"] += t_resp - t_fire
	_phase_us["conquest"] += t_conq - t_resp
	_phase_us["match"] += t_match - t_conq
	_phase_us["snap"] += t_snap - t_match
	_phase_ticks += 1
	_tele.record_tick_ms(float(t_snap - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0
	if _match_over_broadcast and _sim.tick >= _match_end_tick + MATCH_END_DRAIN_TICKS:
		print("[server] match complete, exiting"); get_tree().quit(0)

func _build_interest() -> void:
	# Built once per tick here so the grid/_positions are reused by BOTH the fire
	# broad-phase (_resolve_fires) and snapshots (_send_snapshots). Consequence: a pawn
	# that respawns later this tick (_handle_respawns) has one-tick-stale interest-set
	# membership in snapshots — its position DATA via state_map() is still fresh; only
	# which interest sets it falls into lags by a tick. Accepted to keep the grid
	# single-build per tick (the perf goal); self-corrects next tick.
	_positions.clear()
	_grid.clear()
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		_positions[id] = p.pos
		_grid.insert(id, p.pos)

func _step_movement() -> void:
	var inputs := {}
	for id in _clients:
		var c = _clients[id]
		var inp = c["queued_input"]
		if inp == null:
			inp = c["last_input"]
			if inp != null: _tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		c["queued_input"] = null
		if c["reloading"] and _sim.tick >= c["reload_done_tick"]:
			c["reloading"] = false
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
	_sim.step(inputs)

func _piece_index(piece_id: String) -> int:
	for i in _catalog.size():
		if _catalog.name_of(i) == piece_id:
			return i
	return -1

func _resolve_fires() -> void:
	for id in _clients:
		var c = _clients[id]
		var inp = c["last_input"]
		if inp == null: continue
		var shooter: Pawn = _sim.world.get_pawn(id)
		if shooter == null or not shooter.alive: continue
		if c["weapon"] == Weapon.RPG:
			c["shot_index"] = 0
			continue   # RPG fires via GADGET_ACTION(GA_RPG_FIRE), not the hit-scan path
		var firing: bool = (inp["buttons"] & InputCommand.BTN_FIRE) != 0
		if not firing:
			c["shot_index"] = 0
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * TICK_RATE))
			continue
		var now := float(_sim.tick) * SimLoop.DT
		var ready: bool = now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting: bool = (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		var drop_shoot: bool = Combat.drop_shoot_blocked(shooter.stance, _sim.tick, shooter.last_stance_change_tick)
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting or drop_shoot:
			if drop_shoot:
				_drop_shoot_blocked += 1
			continue
		c["last_fire_time"] = now
		c["ammo"] -= 1
		var shot_index: int = c["shot_index"]
		c["shot_index"] = shot_index + 1
		_shots += 1
		_fire_shot(id, shooter, inp, shot_index)

func _fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = _clients[shooter_id]["weapon"]
	var wdef: Dictionary = _clients[shooter_id]["weapon_def"]
	var prone: bool = shooter.stance == Stance.PRONE
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, _sim.tick, shot_index, moving, prone, wdef)

	var view_tick: int = inp["view_server_tick"]
	if view_tick < _sim.tick - LagComp.MAX_REWIND or view_tick > _sim.tick:
		_rewind_clamped += 1
	var frame := _lag.rewind(view_tick)

	var max_range: float = wdef["range_m"]
	# Broad-phase: only candidates near the shooter (current positions + lag-comp margin),
	# instead of scanning the whole rewound frame. Objective clustering raises density, so
	# this keeps per-shot cost bounded. Precise test still uses the rewound state.
	var candidates: Array = _grid.query(shooter.pos, max_range + FIRE_RANGE_MARGIN, _positions)
	var best_t := max_range + 1.0
	var best_victim := 0
	var best_head := false
	for tid in candidates:
		if tid == shooter_id: continue
		if not frame.has(tid): continue
		var st = frame[tid]
		if not st["alive"] or st["team"] == shooter.team: continue
		var to_target: Vector3 = st["pos"] - ray["origin"]
		if to_target.length() > max_range: continue
		if to_target.normalized().dot(ray["dir"]) < FIRE_CONE_DOT: continue
		var hit := Hitbox.raycast_pawn(ray["origin"], ray["dir"], st["pos"], st["stance"], max_range)
		if hit["hit"] and hit["t"] < best_t:
			best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]

	# Resolve the enemy hit damage up front (incl. headshot/range) — penetration scales it.
	var enemy_dmg := 0
	if best_victim != 0:
		enemy_dmg = Combat.damage_for(wid, best_head, best_t, wdef)
	var body_dmg := int(wdef["damage_body"])

	# Cover / penetration: a structure strictly nearer than the enemy is in the way.
	if _store.count() > 0:
		# Only a structure NEARER than the resolved enemy hit can change the outcome, so bound
		# the march by best_t (the enemy distance) when an enemy was hit — in combat that is the
		# engagement range, far short of the full weapon range, cutting per-shot march cost.
		# When no enemy was hit, march the full range to detect a pure cover absorb.
		var march_max: float = best_t if best_victim != 0 else max_range
		var blocked := _store.march(ray["origin"], ray["dir"], march_max)
		if blocked["hit"] and float(blocked["dist"]) < best_t:
			var block_id := int(blocked["id"])
			var rec: Dictionary = _store.get_record(block_id)
			if rec.is_empty():
				return   # piece gone (defensive; matches the guard in _emit_structure_deltas)
			var mat := _catalog.material_of(int(rec["type"]))
			# `blk` counts every shot a piece was interposed on (pen OR stop); `pen` (below) counts
			# only the subset that penetrated through. They overlap by design — blk is "intersected".
			_shots_blocked += 1
			if not PieceCatalog.is_penetrable(mat):
				_damage_structure(block_id, body_dmg)   # non-pen: piece eats it, shot stops
				return
			# Penetrable: piece takes body*absorption; if it survives, bullet exits at *transmit.
			var split := Combat.apply_penetration(body_dmg, enemy_dmg,
				PieceCatalog.absorption_of(mat), PieceCatalog.transmit_of(mat))
			_damage_structure(block_id, int(split["piece_damage"]))
			if _store.get_record(block_id).is_empty():
				return   # 1-pen: a piece destroyed this shot consumes the bullet
			if best_victim == 0:
				return   # nothing beyond to hit
			_pen += 1
			enemy_dmg = int(split["exit_damage"])

	if best_victim == 0 or enemy_dmg <= 0:
		return
	_hits += 1
	var victim: Pawn = _sim.world.get_pawn(best_victim)
	if victim == null or not victim.alive: return
	_apply_pawn_damage(best_victim, victim, enemy_dmg, best_head, Revive.Source.BULLET, shooter_id, wid)

func _is_medic(id: int) -> bool:
	return _clients.has(id) and int(_clients[id]["class"]) == Loadout.MEDIC

func _down_pawn(victim: Pawn) -> void:
	victim.is_downed = true
	victim.bleed_health = 0
	victim.bleed_halted = false
	_downed += 1
	# No ticket cost and no KILL event at down — only true death spends a ticket.

func _kill_pawn(vid: int, victim: Pawn, killer_id: int, weapon_id: int, headshot: bool, source: int) -> void:
	victim.alive = false
	victim.is_downed = false
	_clients[vid]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
	_conquest.register_death(victim.team)
	_kills += 1
	if source == Revive.Source.BLAST:
		_splash_kills += 1
	var ev := Protocol.encode_kill(vid, killer_id, weapon_id, headshot)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, ev, ENetPacketPeer.FLAG_RELIABLE)

## Single routing path for all pawn damage. A standing pawn is killed outright by a headshot or
## blast (instant-kill bypass) and otherwise downed. DOWNED pawns are immune to weapon damage
## (no finishing, BattleBit-style) — they resolve only via passive bleed-out or a teammate revive.
func _apply_pawn_damage(vid: int, victim: Pawn, dmg: int, headshot: bool, source: int,
		killer_id: int, weapon_id: int) -> void:
	if victim.is_downed:
		return  # immune to damage while downed
	victim.health -= dmg
	if victim.health > 0:
		return
	victim.health = 0
	if Revive.is_instant_kill(headshot, source):
		_kill_pawn(vid, victim, killer_id, weapon_id, headshot, source)
	else:
		_down_pawn(victim)

func _complete_revive(target_id: int) -> void:
	var p: Pawn = _sim.world.get_pawn(target_id)
	if p == null: return
	p.is_downed = false
	p.health = Revive.REVIVE_HP
	p.bleed_health = 0
	p.bleed_halted = false
	_revives += 1
	# No ticket refund needed — DOWNED never spent one.

## Accumulate revive progress for downed teammates being held by an in-range, alive reviver.
## Revive intent is LATCHED — set by REVIVE_ACTION(active) and held in `_reviving` across ticks
## until the revive ends — so a per-tick REVIVE_ACTION packet dropped under fleet input-starvation
## does NOT reset progress. Validity is re-checked each tick against authoritative state, so only the
## reviver actually leaving range interrupts the hold; the latch is dropped when the revive is over.
func _step_revives() -> void:
	var active_targets := {}   # target_id -> reviver_id (one reviver advances a target per tick)
	var done: Array = []       # latched intents to drop: revive ended or can never succeed
	for reviver_id in _reviving:
		var target_id: int = _reviving[reviver_id]
		var rp: Pawn = _sim.world.get_pawn(reviver_id)
		var tp: Pawn = _sim.world.get_pawn(target_id)
		if tp == null or not tp.is_downed: done.append(reviver_id); continue          # target resolved
		if rp == null or not rp.alive or rp.is_downed: done.append(reviver_id); continue  # reviver can't
		if tp.team != rp.team: done.append(reviver_id); continue                       # enemy can't revive
		if rp.pos.distance_to(tp.pos) > Revive.REVIVE_RANGE: continue                  # transient: hold latch, no progress
		active_targets[target_id] = reviver_id
	# Drop accumulated progress for downed targets with no in-range reviver this tick.
	for t in _revive_ticks.keys():
		if not active_targets.has(t):
			_revive_ticks.erase(t)
	# Advance + complete.
	for target_id in active_targets:
		var reviver_id: int = active_targets[target_id]
		_revive_ticks[target_id] = int(_revive_ticks.get(target_id, 0)) + 1
		if _revive_ticks[target_id] >= Revive.revive_ticks(_is_medic(reviver_id)):
			_complete_revive(target_id)
			_revive_ticks.erase(target_id)
			done.append(reviver_id)
	for rid in done:
		_reviving.erase(rid)

## RMB active give: each held giver raycasts from its aim at one teammate in range and heals
## (medic) or resupplies (support) at the active rate. Latched like revive — held in _giving until
## GA_GIVE_STOP or invalidation.
func _step_active_give() -> void:
	if _giving.is_empty():
		return
	var done: Array = []
	for gid in _giving:
		var giver: Pawn = _sim.world.get_pawn(gid)
		if giver == null or not giver.alive or giver.is_downed: done.append(gid); continue
		var kind := _giver_kind(int(_clients[gid]["class"]))
		if kind == -1: done.append(gid); continue
		var gdef: Dictionary = _gadgets.def_of_kind(kind)
		var aim := Combat._forward(giver.yaw, giver.pitch)
		var rng := float(gdef["give_range"])
		# Find the nearest in-range teammate on the aim ray.
		var target := 0
		var best := INF
		for tid in _sim.world.pawns:
			if tid == gid: continue
			var t: Pawn = _sim.world.pawns[tid]
			# Downed teammates are handled by revive (P1), not give/resupply — skip them.
			if not t.alive or t.is_downed or t.team != giver.team: continue
			var d2 := giver.pos.distance_to(t.pos)
			if d2 <= rng and d2 < best and Gadget.give_hits(giver.eye_position(), aim, t.pos, t.stance, rng):
				best = d2; target = tid
		if target == 0: continue   # nothing to give to this tick; keep the latch
		if kind == Gadget.KIND_HEAL:
			_give_heal(target, int(gdef["active_rate"]))
		else:
			_give_ammo(target, int(gdef["active_rate"]))
	for gid in done:
		_giving.erase(gid)

## Heals target by `rate` HP, capped at 100. No-op if dead or already full.
func _give_heal(target_id: int, rate: int) -> void:
	var t: Pawn = _sim.world.get_pawn(target_id)
	if t == null or not t.alive or t.health >= 100: return
	t.health = mini(100, t.health + rate)
	_heals += 1

## Ammo give at 1 mag per `period` ticks (active_rate is the period). Refills ammo + a bandage.
func _give_ammo(target_id: int, period: int) -> void:
	if period <= 0 or _sim.tick % period != 0: return
	if not _clients.has(target_id): return
	var tc = _clients[target_id]
	var cap: int = int(Weapon.get_def(int(tc["weapon"]))["mag_size"])
	if int(tc["ammo"]) >= cap and _pawn_bandages_full(target_id): return
	tc["ammo"] = cap
	var tp: Pawn = _sim.world.get_pawn(target_id)
	if tp != null:
		tp.bandage_count = Revive.bandage_count_for(_is_medic(target_id))
	_ammo_gives += 1

func _pawn_bandages_full(id: int) -> bool:
	var p: Pawn = _sim.world.get_pawn(id)
	return p != null and p.bandage_count >= Revive.bandage_count_for(_is_medic(id))

## Per-tick bleed for every downed pawn; bleed-out is a true death (spends a ticket).
func _step_downed() -> void:
	for id in _clients:
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or not p.is_downed:
			continue
		p.bleed_health = Revive.bleed_step(p.bleed_health, p.bleed_halted)
		if Revive.is_bled_out(p.bleed_health):
			_kill_pawn(id, p, id, 0, false, Revive.Source.BULLET)  # killer = self (bleed-out)
			_bleedouts += 1

func _handle_respawns() -> void:
	for id in _clients:
		var c = _clients[id]
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or p.alive: continue
		if c["respawn_tick"] > 0 and _sim.tick >= c["respawn_tick"]:
			p.pos = _select_spawn(id)
			p.velocity = Vector3.ZERO
			p.health = 100
			p.alive = true
			p.stamina = Pawn.STAMINA_MAX
			p.is_downed = false
			p.bleed_halted = false
			p.bandage_count = Revive.bandage_count_for(_is_medic(id))
			c["respawn_tick"] = 0
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
			c["reloading"] = false
			c["rockets"] = int(_gadgets.def_of_kind(Gadget.KIND_RPG)["max_active"]) if int(c["weapon"]) == Weapon.RPG else 0

func _select_spawn(id: int) -> Vector3:
	var c = _clients[id]
	var team: int = c["team"]
	var obj := _objective_for(team)
	var mates: Array = []
	for mid in _squads.members(team, c["squad"]):
		if mid == id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp != null and mp.alive: mates.append(mp.pos)
	return SpawnSelect.select(team, _map, _conquest, mates, obj)

func _objective_for(team: int) -> Vector3:
	var base := _map.base_for(team)
	var from: Vector3 = base["pos"] if not base.is_empty() else Vector3.ZERO
	var idx := _conquest.nearest_capturable_index(team, from)
	return _conquest.points[idx]["pos"] if idx >= 0 else from

func _owner_snapshot() -> Array:
	var a: Array = []
	for pt in _conquest.points: a.append(pt["owner"])
	return a

func _track_and_broadcast_match_state() -> void:
	var owners := _owner_snapshot()
	for i in owners.size():
		if i < _prev_owners.size() and owners[i] != _prev_owners[i]:
			_cap_events += 1
			_cap_events_total += 1
	_prev_owners = owners
	if _conquest.match_over and not _match_over_broadcast:
		_match_over_broadcast = true
		_match_end_tick = _sim.tick
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], true, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
		print("[match] OVER winner=%d t0=%d t1=%d elapsed=%ds cap_events=%d"
			% [_conquest.winner, _conquest.tickets_int(0), _conquest.tickets_int(1), int(_conquest.elapsed), _cap_events_total])
	elif not _match_over_broadcast and _sim.tick % MATCH_STATE_INTERVAL == 0:
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], false, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	for id in _clients:
		# Stagger sends across ticks so the per-tick snapshot encode cost (the dominant tick
		# cost at high player counts) is ~clients/SNAPSHOT_STRIDE rather than O(clients).
		if (_sim.tick + id) % SNAPSHOT_STRIDE != 0:
			continue
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		_sync_structure_baselines(c, self_pawn.pos)
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, _positions)
		if ids.size() > MAX_SNAPSHOT_ENTITIES:
			# Cull ENEMIES only — they are the sole wallhack concern. Every TEAMMATE in interest
			# range is always replicated: there is no security reason to hide friendlies, and a
			# client must see its downed squadmates to revive them (hard count-culling hid them at
			# fleet density, which broke revive). Enemies are kept nearest-first up to
			# MAX_ENEMY_SNAPSHOT. Self always kept (needed for reconciliation). Only paid over cap.
			# (True 256-scale wants rate/precision LOD on distant entities — separate netcode work.)
			var sp: Vector3 = self_pawn.pos
			var myteam: int = self_pawn.team
			var kept := {id: true}
			var enemies: Array = []
			for vid in ids:
				if vid == id: continue
				if int(state[vid].team) == myteam:
					kept[vid] = true   # always replicate every teammate in range
				else:
					enemies.append([sp.distance_squared_to(_positions[vid]), vid])
			enemies.sort()   # nearest enemies first
			var enemy_kept := 0
			for pair in enemies:
				if enemy_kept >= MAX_ENEMY_SNAPSHOT:
					break
				kept[pair[1]] = true
				enemy_kept += 1
			ids = kept.keys()
		var current := {}
		for vid in ids: current[vid] = state[vid]
		var baseline_seq: int = c["last_acked_seq"]
		var baseline = c["history"].get(baseline_seq)
		if baseline == null:
			baseline = {}; baseline_seq = 0
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, baseline_seq, c["last_input_tick"], current, baseline)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)
		c["history"][seq] = current
		c["next_seq"] = seq + 1
		var cutoff := seq - MAX_HISTORY
		for s in c["history"].keys():
			if s < cutoff: c["history"].erase(s)
		_tele.add_bytes(id, bytes.size())

func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO: _handle_hello(peer, bytes)
		Protocol.Msg.INPUT: _handle_input(peer, bytes)
		Protocol.Msg.BUILD_REQUEST: _handle_build_request(peer, bytes)
		Protocol.Msg.BUILD_REMOVE: _handle_build_remove(peer, bytes)
		Protocol.Msg.GRENADE_THROW: _handle_grenade_throw(peer, bytes)
		Protocol.Msg.REVIVE_ACTION: _handle_revive_action(peer, bytes)
		Protocol.Msg.SELF_BANDAGE: _handle_self_bandage(peer, bytes)
		Protocol.Msg.GADGET_ACTION: _handle_gadget_action(peer, bytes)
		_: pass

func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	if _clients.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	var id := _next_id
	_next_id += 1
	var team: int = 0 if _team_counts[0] <= _team_counts[1] else 1
	_team_counts[team] += 1
	var cls := Loadout.random_class()
	var wid: int = Loadout.weapon_for(cls)
	if cls == Loadout.ENGINEER and id % 3 == 0:
		wid = Weapon.RPG
	if not Loadout.can_equip(cls, wid):   # authoritative guard (RPG -> Engineer only)
		wid = Loadout.weapon_for(cls)
	var attachments := Loadout.default_attachments()
	var weapon_def := Weapon.effective_def(wid, _attachments.multipliers(attachments))
	var start_rockets := int(_gadgets.def_of_kind(Gadget.KIND_RPG)["max_active"]) if wid == Weapon.RPG else 0
	var squad := _squads.assign(id, team)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {},
		"team": team, "squad": squad, "class": cls, "weapon": wid, "weapon_def": weapon_def,
		"rockets": start_rockets, "last_rocket_tick": -100000,
		"ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "respawn_tick": 0,
		"last_build_tick": -100000, "last_grenade_tick": -100000, "known_regions": {},
	}
	var p := _sim.world.spawn(id)
	p.team = team
	p.squad = squad
	p.pos = _select_spawn(id)
	p.bandage_count = Revive.bandage_count_for(cls == Loadout.MEDIC)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE, cls), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d squad=%d class=%d — %d peers" % [id, pname, team, squad, cls, _clients.size()])

func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	if c["queued_input"] != null and d["client_tick"] <= c["queued_input"]["client_tick"]: return
	c["queued_input"] = d
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack: c["history"].erase(s)

func _handle_build_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var d := Protocol.decode_build_request(bytes)
	var type: int = d["type"]
	if type < 0 or type >= _catalog.size(): return
	var cell: Vector3i = d["cell"]
	var v := _store.validate_place(cell, p.pos, _sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if _store.owner_count(id) >= StructureStore.MAX_PIECES_PER_PLAYER:
		var old_id := _store.oldest_id(id)
		if old_id != 0:
			var old_cell := _cell_of_struct(old_id)   # capture BEFORE removal (record still present)
			_store.recycle_oldest(id)
			_removes += 1
			_emit_structure_delta(Protocol.OP_REMOVE, {"id": old_id}, old_cell)
	var sid := _next_struct_id
	_next_struct_id += 1
	var rec := _store.place(sid, type, cell, d["yaw"], id)
	if rec.is_empty(): return   # lost a race for the cell
	c["last_build_tick"] = _sim.tick
	_builds += 1
	_emit_structure_delta(Protocol.OP_PLACE, rec, cell)

func _handle_build_remove(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var rid: int = Protocol.decode_build_remove(bytes)["id"]
	var rec := _store.get_record(rid)
	if rec.is_empty() or int(rec["owner"]) != id: return
	var cell: Vector3i = rec["cell"]
	_store.remove(rid)
	_removes += 1
	_emit_structure_delta(Protocol.OP_REMOVE, {"id": rid}, cell)

func _handle_grenade_throw(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	if _sim.tick - int(c["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS: return
	var d := Protocol.decode_grenade_throw(bytes)
	var dir: Vector3 = d["dir"]
	if dir.length() < 0.001: return
	c["last_grenade_tick"] = _sim.tick
	_grenades.append({
		"owner": id, "team": p.team, "type": int(d["type"]),
		"pos": p.eye_position(), "vel": Grenade.launch_velocity(dir),
		"detonate_tick": _sim.tick + GRENADE_FUSE_TICKS,
	})

func _handle_gadget_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive or p.is_downed: return
	var d := Protocol.decode_gadget_action(bytes)
	match int(d["action"]):
		Protocol.GA_RPG_FIRE: _fire_rocket(id, p, d["dir"])
		Protocol.GA_C4_PLACE: _place_c4(id, p, d["pos"])
		Protocol.GA_C4_DETONATE: _detonate_c4(id)
		Protocol.GA_MINE_PLACE: _place_mine(id, p, d["pos"], d["dir"])
		Protocol.GA_GIVE_START: _giving[id] = _sim.tick
		Protocol.GA_GIVE_STOP: _giving.erase(id)
		Protocol.GA_BAG_THROW: _throw_bag(id, p, d["pos"])
		_: pass

## Launch an RPG rocket if the player has the RPG equipped, rockets remaining, and is off cooldown.
func _fire_rocket(id: int, p: Pawn, dir: Vector3) -> void:
	var c = _clients[id]
	if int(c["weapon"]) != Weapon.RPG: return
	if int(c["rockets"]) <= 0: return
	var rdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_RPG)
	if _sim.tick - int(c["last_rocket_tick"]) < int(rdef["cooldown_ticks"]): return
	if dir.length() < 0.001: return
	c["last_rocket_tick"] = _sim.tick
	c["rockets"] = int(c["rockets"]) - 1
	_rockets.append({"owner": id, "team": p.team, "pos": p.eye_position(), "vel": Grenade.launch_velocity(dir)})

func _place_c4(id: int, p: Pawn, pos: Vector3) -> void:
	if Loadout.gadget_for(int(_clients[id]["class"])) != Loadout.GADGET_C4: return
	var cdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_C4)
	var owned: Array = _c4.get(id, [])
	if owned.size() >= int(cdef["max_active"]): return
	if p.pos.distance_to(pos) > StructureStore.BUILD_RANGE: return   # within reach
	owned.append({"pos": pos, "cell": BuildGrid.cell_of(Vector3(pos.x, 0.0, pos.z))})
	_c4[id] = owned

func _place_mine(id: int, p: Pawn, pos: Vector3, facing: Vector3) -> void:
	if Loadout.gadget_for(int(_clients[id]["class"])) != Loadout.GADGET_MINE: return
	var mdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_MINE)
	var mine_count := 0
	for m in _mines:
		if int(m["owner"]) == id: mine_count += 1
	if mine_count >= int(mdef["max_active"]): return
	if p.pos.distance_to(pos) > float(mdef["place_range"]): return
	var face := facing.normalized() if facing.length() > 0.001 else Vector3(sin(p.yaw), 0.0, cos(p.yaw))
	_mines.append({"owner": id, "team": p.team, "pos": pos, "facing": face,
		"armed_after_tick": _sim.tick + int(mdef["arm_delay_ticks"])})

func _throw_bag(id: int, p: Pawn, pos: Vector3) -> void:
	var kind := _giver_kind(int(_clients[id]["class"]))
	if kind == -1: return
	var gdef: Dictionary = _gadgets.def_of_kind(kind)
	var bag_count := 0
	for b in _bags:
		if int(b["owner"]) == id: bag_count += 1
	if bag_count >= int(gdef["max_bags"]): return
	_bags.append({"owner": id, "team": p.team, "kind": kind, "pos": pos, "pool": int(gdef["bag_pool"])})
	_bags_thrown += 1

## Maps a class to its give-tool kind (heal/ammo), or -1 if the class has no give tool.
func _giver_kind(cls: int) -> int:
	var g := Loadout.gadget_for(cls)
	if g == Loadout.GADGET_HEAL: return Gadget.KIND_HEAL
	if g == Loadout.GADGET_AMMO: return Gadget.KIND_AMMO
	return -1

func _detonate_c4(id: int) -> void:
	var owned: Array = _c4.get(id, [])
	if owned.is_empty(): return
	var cdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_C4)
	var team: int = _sim.world.get_pawn(id).team if _sim.world.get_pawn(id) != null else int(_clients[id]["team"])
	for c4 in owned:
		_c4_det += 1
		_blast_at(c4["pos"], id, team, int(cdef["pawn_damage"]), float(cdef["pawn_radius"]),
			int(cdef["struct_damage"]), float(cdef["struct_radius"]))
	_c4.erase(id)

## Drop any placed C4 whose ground cell matches a just-destroyed structure cell (spec §"C4").
func _remove_c4_on_cell(cell: Vector3i) -> void:
	for owner in _c4:
		var kept: Array = []
		for c4 in _c4[owner]:
			if c4["cell"] != cell:
				kept.append(c4)
		_c4[owner] = kept

func _handle_self_bandage(peer: ENetPacketPeer, _bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.is_downed or p.bleed_halted: return
	if p.bandage_count <= 0: return
	p.bandage_count -= 1
	p.bleed_halted = true

func _handle_revive_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var d := Protocol.decode_revive_action(bytes)
	if bool(d["active"]):
		_reviving[id] = int(d["target"])
	else:
		_reviving.erase(id)

## Integrate live grenades; detonate on fuse or ground contact (v1). Detonation is present-time.
func _step_grenades() -> void:
	if _grenades.is_empty():
		return
	var still: Array = []
	for g in _grenades:
		if _sim.tick >= int(g["detonate_tick"]):
			_detonate(g)
			continue
		var s := Grenade.integrate(g["pos"], g["vel"], SimLoop.DT)
		g["pos"] = s["pos"]; g["vel"] = s["vel"]
		if g["pos"].y <= 0.0:
			g["pos"].y = 0.0
			_detonate(g)
		else:
			still.append(g)
	_grenades = still

## Generalized blast: structure damage (cell radius) + pawn splash (sphere, current positions,
## FF-off incl. owner). Shared by frag grenades, RPG, C4, and mines. `source` tags the kill
## (BLAST). Returns the number of pawns that took damage (for kill/trigger bookkeeping).
func _blast_at(center: Vector3, owner: int, team: int, pawn_dmg: int, pawn_radius: float,
		struct_dmg: int, struct_radius: float) -> int:
	if struct_dmg > 0 and struct_radius > 0.0:
		for sid in _store.ids_in_radius(center, struct_radius):
			var rec: Dictionary = _store.get_record(sid)
			if rec.is_empty(): continue
			var at := BuildGrid.cell_min(rec["cell"]) + Vector3.ONE * (BuildGrid.CELL_SIZE * 0.5)
			var sd := Grenade.falloff_damage(center, at, struct_dmg, struct_radius)
			if sd > 0:
				_damage_structure(sid, sd)
	var hits := 0
	for pid in _sim.world.pawns:
		if pid == owner: continue
		var victim: Pawn = _sim.world.pawns[pid]
		if not victim.alive or victim.team == team: continue
		var pd := Grenade.falloff_damage(center, victim.pos, pawn_dmg, pawn_radius)
		if pd <= 0: continue
		_apply_pawn_damage(pid, victim, pd, false, Revive.Source.BLAST, owner, 0)
		hits += 1
	return hits

## Integrate live RPG rockets; detonate on structure march-hit or ground contact. Reuses the
## Grenade ballistic model (spec §"RPG"). Present-time blast via _blast_at; FF-off.
func _step_rockets() -> void:
	if _rockets.is_empty():
		return
	var rdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_RPG)
	var still: Array = []
	for r in _rockets:
		var s := Grenade.integrate(r["pos"], r["vel"], SimLoop.DT)
		var nxt: Vector3 = s["pos"]
		# Structure contact along this step (march from old pos toward new).
		var seg: Vector3 = nxt - (r["pos"] as Vector3)
		var seg_len := seg.length()
		var struck := false
		if _store.count() > 0 and seg_len > 0.0001:
			var m := _store.march(r["pos"], seg / seg_len, seg_len)
			if bool(m["hit"]):
				struck = true
		if struck or nxt.y <= 0.0:
			if nxt.y < 0.0: nxt.y = 0.0
			_rockets_det += 1
			_rstruct += _store.ids_in_radius(nxt, float(rdef["struct_radius"])).size()
			_blast_at(nxt, int(r["owner"]), int(r["team"]),
				int(rdef["pawn_damage"]), float(rdef["pawn_radius"]),
				int(rdef["struct_damage"]), float(rdef["struct_radius"]))
			continue
		r["pos"] = nxt; r["vel"] = s["vel"]
		still.append(r)
	_rockets = still

## Proximity check for armed mines: if an enemy enters the trigger cone, detonate (FF-off blast).
## O(mines × pawns); mine count is capped per player. Claymore = directional cone (spec §"Mine").
func _step_mines() -> void:
	if _mines.is_empty():
		return
	var mdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_MINE)
	var radius := float(mdef["trigger_radius"])
	var half_angle := deg_to_rad(60.0) if bool(mdef.get("directional", false)) else PI
	var still: Array = []
	for m in _mines:
		if _sim.tick < int(m["armed_after_tick"]):
			still.append(m); continue
		var tripped := false
		for pid in _sim.world.pawns:
			var v: Pawn = _sim.world.pawns[pid]
			if not v.alive or v.team == int(m["team"]): continue
			if Gadget.in_cone(m["pos"], m["facing"], v.pos, radius, half_angle):
				tripped = true; break
		if tripped:
			_mine_trips += 1
			_blast_at(m["pos"], int(m["owner"]), int(m["team"]), int(mdef["pawn_damage"]),
				float(mdef["pawn_radius"]), 0, 0.0)
		else:
			still.append(m)
	_mines = still

## Frag: area damage at the grenade's current position — structures (cell radius) + pawns (sphere,
## current positions, FF-off incl. thrower). Removes/bucket-drops route through _damage_structure.
## (Smoke is handled by a branch added in Task 9.)
func _detonate(g: Dictionary) -> void:
	if int(g["type"]) == Grenade.SMOKE:
		_deploy_smoke(g)
		return
	_nades += 1
	_blast_at(g["pos"], int(g["owner"]), int(g["team"]), GRENADE_DAMAGE_PAWN, BLAST_PAWN_RADIUS, GRENADE_DAMAGE_STRUCT, BLAST_STRUCT_RADIUS)

## Smoke detonation: no damage. Record a server-side zone and broadcast it (low-frequency, like
## KILL — bounded by the throw cooldown). M7 LOS culling will read _smoke_zones; here it just
## replicates the zone so clients know it exists.
func _deploy_smoke(g: Dictionary) -> void:
	_smokes += 1
	var expire: int = _sim.tick + SMOKE_DURATION_TICKS
	_smoke_zones.append({"pos": g["pos"], "radius": SMOKE_RADIUS, "expire_tick": expire})
	var bytes := Protocol.encode_smoke_deployed(g["pos"], SMOKE_RADIUS, expire)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## Drop expired smoke zones (O(zones); negligible). Keeps _smoke_zones bounded for the M7 reader.
func _expire_smoke_zones() -> void:
	if _smoke_zones.is_empty():
		return
	var live: Array = []
	for z in _smoke_zones:
		if _sim.tick < int(z["expire_tick"]):
			live.append(z)
	_smoke_zones = live

## Thrown bags dispense to every teammate in radius at 25% of the active rate, drawing from a
## finite pool; a bag vanishes when its pool hits 0 (spec §"Medic heal tool & Support ammo tool").
func _step_bags() -> void:
	if _bags.is_empty():
		return
	var still: Array = []
	for b in _bags:
		var kind: int = int(b["kind"])
		var gdef: Dictionary = _gadgets.def_of_kind(kind)
		var radius := float(gdef["bag_radius"])
		var dispensed := 0
		for pid in _sim.world.pawns:
			var t: Pawn = _sim.world.pawns[pid]
			if not t.alive or t.is_downed or t.team != int(b["team"]): continue
			if t.pos.distance_to(b["pos"]) > radius: continue
			if kind == Gadget.KIND_HEAL:
				if t.health >= 100: continue
				# Integer div (active_rate=2 → 0), floored to 1 so low-rate bags still make progress.
				var amt := maxi(1, int(gdef["active_rate"]) / 4)
				t.health = mini(100, t.health + amt)
				dispensed += amt
				_heals += 1
			else:
				# Ammo bag: top up at most once per active period, costing 1 pool (mag).
				if _sim.tick % maxi(1, int(gdef["active_rate"]) * 4) != 0: continue
				if not _clients.has(pid): continue
				var tc = _clients[pid]
				var cap: int = int(Weapon.get_def(int(tc["weapon"]))["mag_size"])
				if int(tc["ammo"]) >= cap: continue
				tc["ammo"] = cap
				dispensed += 1
				_ammo_gives += 1
		if dispensed > 0:
			b["pool"] = Gadget.decrement_pool(int(b["pool"]), dispensed)
		if int(b["pool"]) <= 0:
			_bags_exhausted += 1
		else:
			still.append(b)
	_bags = still

## Cell of a still-present record (for remove-delta routing). Returns a far cell if gone.
func _cell_of_struct(id: int) -> Vector3i:
	var rec := _store.get_record(id)
	return rec["cell"] if not rec.is_empty() else Vector3i(0, 0, 0)

## Apply damage to a piece and record the side effects for end-of-tick replication
## (_emit_structure_deltas). Destruction queues a remove + frees the cell (in apply_damage);
## a non-lethal hit marks the piece for a bucket-diff check.
func _damage_structure(id: int, amount: int) -> void:
	var cell := _cell_of_struct(id)       # capture BEFORE possible removal
	var res := _store.apply_damage(id, amount)
	if not res["hit"]:
		return
	_dmg += 1
	if res["destroyed"]:
		_destroyed += 1
		_pending_removes.append({"id": id, "cell": cell})
		_dmg_touched.erase(id)
		_last_bucket.erase(id)
		_remove_c4_on_cell(cell)
	else:
		_dmg_touched[id] = true

## Flush queued removes + bucket drops to interested clients, bounded by
## MAX_STRUCTURE_DELTAS_PER_TICK (removes first; overflow carried to next tick). Authoritative
## state is already applied — only the SEND volume is throttled. See docs/specs/destruction.md.
func _emit_structure_deltas() -> void:
	var budget := MAX_STRUCTURE_DELTAS_PER_TICK
	while not _pending_removes.is_empty() and budget > 0:
		var r: Dictionary = _pending_removes.pop_front()
		_removes += 1
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": r["id"]}, r["cell"])
		budget -= 1
	for id in _dmg_touched.keys():
		if budget <= 0:
			break
		var rec := _store.get_record(id)
		if rec.is_empty():
			_dmg_touched.erase(id)
			continue
		var max_health := _catalog.health_of(int(rec["type"]))
		var bucket := StructureStore.bucket_of(int(rec["health"]), max_health)
		if bucket < int(_last_bucket.get(id, 3)):
			_last_bucket[id] = bucket
			_emit_structure_delta(Protocol.OP_DAMAGE, {"id": id, "bucket": bucket}, rec["cell"])
		_dmg_touched.erase(id)
		budget -= 1

## Send a structure delta to every client whose current interest region covers the cell's region.
func _emit_structure_delta(op: int, rec: Dictionary, cell: Vector3i) -> void:
	var region := _store.region_of(cell)
	var bytes := Protocol.encode_structure_delta(op, rec)
	for cid in _clients:
		if _clients[cid]["known_regions"].has(region):
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## After computing a client's interest entities, send baselines for any structured regions
## newly covered by its interest set. known_regions caches what the client already has.
func _sync_structure_baselines(c: Dictionary, self_pos: Vector3) -> void:
	if _store.count() == 0:
		return
	var center := _grid.key_of(self_pos)
	var span := int(ceil(INTEREST_RADIUS / CELL_SIZE))
	var known: Dictionary = c["known_regions"]
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var region := Vector2i(center.x + dx, center.y + dz)
			if known.has(region):
				continue
			var recs := _store.records_in_region(region)
			if recs.is_empty():
				continue
			known[region] = true
			var bytes := Protocol.encode_structure_baseline(region, recs)
			_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0 and _clients.has(id):
		var team: int = _clients[id]["team"]
		_team_counts[team] -= 1
		_squads.remove(id, team)
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var hit_rate := 0.0 if _shots == 0 else float(_hits) / float(_shots)
	var pts := ""
	for pt in _conquest.points:
		pts += "." if pt["owner"] == -1 else str(pt["owner"])
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d struct=%d bld=%d rmv=%d blk=%d pen=%d dmg=%d destroyed=%d nades=%d splash=%d smoke=%d rockets=%d rstruct=%d downed=%d bleedouts=%d revives=%d c4=%d mines=%d heals=%d ammo=%d bags=%d bagx=%d climbs=%d vaults=%d dropblk=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped, _conquest.tickets_int(0), _conquest.tickets_int(1), pts, _cap_events, _store.count(), _builds, _removes, _shots_blocked, _pen, _dmg, _destroyed, _nades, _splash_kills, _smokes, _rockets_det, _rstruct, _downed, _bleedouts, _revives, _c4_det, _mine_trips, _heals, _ammo_gives, _bags_thrown, _bags_exhausted, _climbs, _vaults, _drop_shoot_blocked])
	var pt := maxi(_phase_ticks, 1)
	print("[perf] us/tick: poll=%d move=%d lag=%d interest=%d fire=%d respawn=%d conquest=%d match=%d snap=%d (ticks=%d)"
		% [_phase_us["poll"] / pt, _phase_us["move"] / pt, _phase_us["lag"] / pt, _phase_us["interest"] / pt, _phase_us["fire"] / pt, _phase_us["respawn"] / pt, _phase_us["conquest"] / pt, _phase_us["match"] / pt, _phase_us["snap"] / pt, _phase_ticks])
	for k in _phase_us: _phase_us[k] = 0
	_phase_ticks = 0
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0; _cap_events = 0
	_builds = 0; _removes = 0; _shots_blocked = 0; _pen = 0
	_dmg = 0; _destroyed = 0; _nades = 0; _splash_kills = 0; _smokes = 0; _rockets_det = 0; _rstruct = 0; _downed = 0; _bleedouts = 0; _revives = 0; _c4_det = 0; _mine_trips = 0; _heals = 0; _ammo_gives = 0; _bags_thrown = 0; _bags_exhausted = 0; _climbs = 0; _vaults = 0; _drop_shoot_blocked = 0
