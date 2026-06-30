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
const FIRE_CONE_SKIP_RANGE := 8.0  # below this, skip the cone cull — feet/chest parallax exceeds the half-angle at point blank
const RPG_RELOAD_SECS := 3.0       # reload refills the rocket pool (RPG has no hit-scan mag)
const FIRE_RANGE_MARGIN := 20.0    # grid broad-phase slack for lag-comp movement
const MAP_PATH := "res://maps/conquest_proving_grounds.json"   # default; override with --map=<name>
const MATCH_STATE_INTERVAL := 15   # ticks between match-state broadcasts (2 Hz)
const KILL_SCORE := 100             # score points awarded to killer per kill
const ROSTER_STRIDE_TICKS := 30    # broadcast roster every N ticks (~1 Hz @30Hz)
const MATCH_END_DRAIN_TICKS := 60  # keep running ~2s after a win, then exit
const MAX_STRUCTURE_DELTAS_PER_TICK := 64   # graceful degradation: cap delta SENDS/tick
const BULLET_CARVE_RADIUS := 0.30   # m: chunks a single blocked bullet clears (M11)
const GRENADE_FUSE_TICKS := 45        # 1.5s @30Hz
const GRENADE_COOLDOWN_TICKS := 300   # 10s between a player's throws (shared frag/smoke)
const BLAST_PAWN_RADIUS := 6.0        # m, sphere (current positions, FF-off)
const BLAST_STRUCT_RADIUS := 4.0      # m (~2 build cells)
const GRENADE_DAMAGE_PAWN := 100      # frag pawn splash at centre, linear falloff
const GRENADE_DAMAGE_STRUCT := 200    # frag structure blast GATE (>0 = enabled; magnitude unused — carve is governed by struct_radius, M11)
const IMPACT_CONTACT_RADIUS := 1.0    # m — an impact grenade detonates this close to an enemy pawn
const MELEE_DAMAGE := 50              # knife body-hit damage (M5.5-P3); rear-arc back-stab instant-kills
const MELEE_COOLDOWN_TICKS := 24      # ~0.8s @30Hz between melee swings
const SLEDGE_PAWN_DAMAGE := 35        # Engineer sledgehammer pawn-bonk (no structure in reach)
const SLEDGE_STRUCT_RADIUS := 1.5     # m — carve radius of one sledge swing on a structure cell
const FLASH_RADIUS := 8.0             # m — flashbang blinds exposed pawns within this radius (any team)
const FLASH_BLIND_TICKS := 90         # 3s @30Hz of white-out at the centre
const SMOKE_DURATION_TICKS := 150     # 5s @30Hz — smoke zone lifetime
const SMOKE_RADIUS := 6.0             # m — smoke zone radius (matches blast radius)
const PIECES_PATH := "res://pieces/pieces.json"
const GADGETS_PATH := "res://data/gadgets.json"
const ATTACHMENTS_PATH := "res://data/attachments.json"
const VEHICLES_PATH := "res://data/vehicles.json"
const ENTER_RANGE := 3.0
const WEAPON_SWAP_TICKS := 12   # equip lockout after a quick-swap (~0.4s @30Hz)
# The flat per-weapon fields kept as the LIVE state of the active slot; frozen into c["slots"] on swap.
const _SLOT_FIELDS := ["weapon", "weapon_def", "ammo", "reloading", "reload_done_tick", "last_fire_time", "shot_index", "fire_mode"]
const RPG_VEHICLE_DMG := 800
const C4_VEHICLE_DMG := 500
const FRAG_VEHICLE_DMG := 80
const MAX_VIEW_RATE := 0.6  # rad/tick; at 30Hz = 18 rad/s (~1031 deg/s) — generous cap for telemetry-only anomaly detection

var _net: NetHost
var _port := 27015
var _start_tickets := -1
var _time_limit := -1.0
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _map: MapDef
var _map_path: String = MAP_PATH   # --map=<name> overrides (must match client + bots)
var _human_rpg := false   # --human-rpg: force human (manual-deploy) players to spawn Engineer + RPG (destruction testing)
var _conquest: ConquestState
var _squads := SquadManager.new()
var _catalog: PieceCatalog
var _store: StructureStore
var _gadgets: Gadget
var _attachments: Attachment
var _vehicles_cat: VehicleCatalog
var _next_struct_id := 1
var _next_id := 1
var _tele_accum := 0.0
# Per-phase tick profiling (mean usec/tick over the telemetry window).
var _phase_us := {"poll": 0, "move": 0, "veh": 0, "lag": 0, "interest": 0, "fire": 0, "respawn": 0, "conquest": 0, "match": 0, "snap": 0}
var _phase_ticks := 0
var _team_counts := {0: 0, 1: 0}
var _positions := {}               # id -> Vector3, rebuilt each tick before fires
var _prev_climb_vault: Dictionary = {}   # id -> int bitmask: bit0=climbing, bit1=vaulting (edge counting)

var _reviving := {}            # reviver_id -> target_id, set per tick by REVIVE_ACTION(active)
var _revive_ticks := {}        # target_id -> accumulated revive ticks
var _being_revived := {}       # target_id -> reviver_id, this tick (drives the downed "being revived" UI)
var _revives := 0              # completed revives this window
var _climbs := 0              # climb-mode entries this window
var _vaults := 0              # vault completions this window
var _drop_shoot_blocked := 0  # shots rejected by the prone-transition gate this window

var _roster_tick := 0
var _gadget_pkt_sent: PackedByteArray = PackedByteArray()   # last GADGET_LIST sent (resend only on change)
var _gadget_hb_tick := 0                                    # last heartbeat tick (covers late joiners)
const GADGET_HEARTBEAT_TICKS := 30                          # resend the (non-empty) list ~1 Hz for late joiners
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
var _sites := BuildSiteStore.new()   # M12-P2: active under-construction build sites
const MAX_SITES_PER_PLAYER := 4
var _built_small := 0
var _built_large := 0
var _build_blocked_solo := 0
var _dismantled := 0
var _repaired := 0
# M12-P3: squad-leader FOB registry. "team:squad" -> {squad, team, id, cell, built: bool}
var _fobs: Dictionary = {}
var _fobs_built := 0           # per-telemetry-window (reset each log)
var _fob_spawns := 0
var _fob_disabled := 0
var _fobs_destroyed := 0
var _shots_blocked := 0
var _pen := 0                 # bullet penetrations through a piece this window
var _dmg := 0                 # damage events applied this window
var _destroyed := 0           # pieces removed by damage/blast this window
var _collapsed := 0           # buildings collapsed this window
var _nades := 0               # frag detonations this window
var _splash_kills := 0        # pawn deaths from blasts this window
var _smokes := 0              # smoke zones deployed this window
var _rockets_det := 0         # RPG rockets detonated this window
var _c4_det := 0              # C4 detonations (per detonate action) this window
var _mine_trips := 0          # claymore/mine detonations this window
var _heals := 0          # active+bag HP-dispensing events this window
var _ammo_gives := 0     # active+bag ammo-resupply events this window
var _enters := 0
var _exits := 0
var _transport_origin := {}   # id -> Vector3 boarding pos (transport-distance metric)
var _transport_max := 0.0     # max carried distance observed this window
var _bags_thrown := 0    # bags deployed this window
var _bags_exhausted := 0 # bags that hit pool 0 and vanished this window
var _rstruct := 0             # structures hit by rockets this window
var _swaps := 0               # weapon quick-swaps this window
var _veh_destroyed := 0
var _rkt_vs_veh := 0
var _pending_removes: Array = []   # [{id, cell}] removes awaiting send (degradation queue)
var _dmg_touched := {}             # id -> true: pieces holed (alive) this tick, for end-of-tick chunk-mask resend
var _buildings_to_cascade := {}    # building_id -> true; resolved at end of tick
var _grenades: Array = []     # [{owner, team, type, pos, vel, detonate_tick}] — server-side, not replicated
var _rockets: Array = []      # [{owner, team, pos, vel}] — server-side, not replicated
const MAX_LIVE_PROJECTILES := 1024
var _projectiles: Array = []  # [{owner, team, weapon_id, wdef, pos, vel, spawn_tick, dist, ttl}] — stepped bullets
var _proj_fired := 0          # projectiles spawned this window
var _proj_hits := 0           # projectiles that connected with a pawn this window
var _proj_live_max := 0       # max concurrent live projectiles observed this window
var _proj_dropped := 0        # spawns refused this window because the pool was at MAX_LIVE_PROJECTILES
var _suppress_events := 0     # near-miss suppression accruals this window (M5.5-P2)
var _melees := 0              # melee swings that landed this window (M5.5-P3)
var _backstabs := 0           # rear-arc instant-kill melee hits this window (M5.5-P3)
var _sledge_hits := 0         # Engineer sledgehammer structure hits this window (M5.5-P3)
var _flashes := 0             # flashbang detonations this window (M5.5-P3)
var _flash_blinds := 0        # pawns blinded by flashbangs this window (M5.5-P3)
var _impacts := 0             # impact-grenade contact detonations this window (M5.5-P3)
var _dbg_last_min_y := INF    # test seam only: lowest y any stepped projectile reached
var _mines: Array = []        # [{owner, team, pos, facing, armed_after_tick}]
var _giving: Dictionary = {}   # giver_id -> tick the give began (latched; cleared on STOP/invalid)
var _support_links_this_tick: Array = []   # [{giver, target, kind}] the give/repair/revive steps actually acted on
var _support_pkt_sent: PackedByteArray = PackedByteArray()   # last SUPPORT_LIST sent (resend only on change)
var _support_hb_tick := 0                                    # last support heartbeat tick (late joiners)
var _repairing := {}        # engineer_id -> true (latched)
var _repair_heat := {}      # engineer_id -> int
var _repair_cd := {}        # engineer_id -> cooldown_until tick
var _repairs := 0           # HP restored this window
var _repair_overheats := 0
var _ac_viol := 0              # view-rate anomalies (telemetry-only, never rejects input)
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
	if args.has("map"):
		_map_path = "res://maps/%s.json" % String(args["map"])
	_human_rpg = args.has("human-rpg")

func _ready() -> void:
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[server] failed to load map %s" % _map_path); get_tree().quit(1); return
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
	# M11: stamp destructible building prefabs, each instance a unique building_id (>=1).
	var _next_building_id := 1
	for b in _map.buildings:
		var pres := BuildingCatalog.load_file("res://buildings/%s.json" % b["prefab"], _catalog)
		if not pres["ok"]:
			push_error("[map] building '%s': %s" % [b["prefab"], pres["error"]]); continue
		var bid := _next_building_id
		_next_building_id += 1
		var origin: Vector3i = b["origin_cell"]
		var inst_yaw: int = int(b["yaw"])
		if inst_yaw < 0 or inst_yaw >= BuildGrid.YAW_STEPS:
			push_error("[map] building '%s' yaw %d out of range" % [b["prefab"], inst_yaw]); continue
		for piece in pres["prefab"]["pieces"]:
			var cell := origin + _rotate_offset(piece["offset"], inst_yaw)
			var bsid := _next_struct_id
			_next_struct_id += 1
			var placed := _store.place(bsid, int(piece["type"]), cell, (int(piece["yaw"]) + inst_yaw) % BuildGrid.YAW_STEPS, -1, bid)
			if placed.is_empty():
				push_error("[map] building '%s' piece at cell %s overlaps an occupied cell (dropped)" % [b["prefab"], cell])
	_gadgets = Gadget.load_file(GADGETS_PATH)
	if _gadgets == null:
		push_error("[server] failed to load gadgets %s" % GADGETS_PATH); get_tree().quit(1); return
	_attachments = Attachment.load_file(ATTACHMENTS_PATH)
	if _attachments == null:
		push_error("[server] failed to load attachments %s" % ATTACHMENTS_PATH); get_tree().quit(1); return
	_vehicles_cat = VehicleCatalog.load_file(VEHICLES_PATH)
	if _vehicles_cat == null:
		push_error("[server] failed to load vehicles %s" % VEHICLES_PATH); get_tree().quit(1); return
	_spawn_map_vehicles()
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
		var cur: int = (1 if p.climbing else 0) | (2 if p.vaulting else 0)
		var prv: int = _prev_climb_vault.get(id, 0)
		if (cur & 1) != 0 and (prv & 1) == 0:
			_climbs += 1
		if (cur & 2) != 0 and (prv & 2) == 0:
			_vaults += 1
		_prev_climb_vault[id] = cur
	var t_move := Time.get_ticks_usec()
	_sim.step_vehicles(_build_vehicle_inputs(), _map.world_half)
	_track_transport_distance()
	var t_veh := Time.get_ticks_usec()
	_lag.record(_sim.tick, _sim.world)
	var t_lag := Time.get_ticks_usec()
	_build_interest()
	var t_int := Time.get_ticks_usec()
	_resolve_fires()
	_resolve_vehicle_fires()
	_step_projectiles()   # bullets spawned by _resolve_fires step in present time (M5.5-P1)
	# M5.5-P2: decay suppression once per tick, after accrual in _step_projectiles (accrue-then-decay).
	for sid in _sim.world.pawns:
		var sp: Pawn = _sim.world.pawns[sid]
		if sp.suppression > 0.0:
			sp.suppression = Suppress.decay(sp.suppression)
	var t_fire := Time.get_ticks_usec()
	_step_grenades()
	_step_rockets()
	_step_mines()
	_support_links_this_tick.clear()   # rebuilt by the give/repair/revive steps below for SUPPORT_LIST
	_step_active_give()
	_step_repairs()
	_step_build_sites()   # M12-P2: cooperative shovel construction / repair / dismantle
	_step_bags()
	_expire_smoke_zones()
	_step_revives()
	_step_downed()
	_handle_respawns()
	_step_vehicle_respawns()
	var t_resp := Time.get_ticks_usec()
	_conquest.step(SimLoop.DT, _sim.world)
	var t_conq := Time.get_ticks_usec()
	_track_and_broadcast_match_state()
	var t_match := Time.get_ticks_usec()
	_resolve_cascades()
	_emit_structure_deltas()
	_send_snapshots()
	_roster_tick += 1
	if _roster_tick % ROSTER_STRIDE_TICKS == 0:
		_broadcast_roster()
	_broadcast_gadget_list()
	_broadcast_support_list()
	_send_fob_lists()
	var t_snap := Time.get_ticks_usec()
	_phase_us["poll"] += t_poll - t0
	_phase_us["move"] += t_move - t_poll
	_phase_us["veh"] += t_veh - t_move
	_phase_us["lag"] += t_lag - t_veh
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
		# Drain one buffered input frame (FIFO, oldest-first). The redundancy bundle (input_command.gd)
		# means a dropped packet's frame is recovered from the next packet's copy, so this rarely
		# starves; when it does (nothing buffered), reuse the last frame and count it.
		var inp = c["input_buf"].pop()
		if inp == null:
			inp = c["last_input"]
			if inp != null: _tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			var prev_inp = c["last_input"]
			if prev_inp != null and inp != prev_inp:
				if not InputValidate.view_rate_ok(float(prev_inp["yaw"]), float(inp["yaw"]), float(prev_inp["pitch"]), float(inp["pitch"]), MAX_VIEW_RATE):
					_ac_viol += 1
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		if c["reloading"] and _sim.tick >= c["reload_done_tick"]:
			c["reloading"] = false
			if int(c["weapon"]) == Weapon.RPG:
				c["rockets"] = int(_gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"])
			else:
				c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
	_sim.step(inputs, _map.world_half)
	_apply_fall_damage()

## Build vid -> driver command from each vehicle's seat-0 (driver) occupant's last input. Also
## refreshes the gunner pawn's look so SimLoop.step_vehicles can mirror it to the turret.
func _build_vehicle_inputs() -> Dictionary:
	var vinputs := {}
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if not v.alive: continue
		var driver: int = int(v.seats[0])
		if driver != 0 and _clients.has(driver) and _clients[driver]["last_input"] != null:
			var inp = _clients[driver]["last_input"]
			vinputs[vid] = {"move_x": InputValidate.clamp_axis(inp["move_x"]),
				"move_y": InputValidate.clamp_axis(inp["move_y"])}
	return vinputs

func _piece_index(piece_id: String) -> int:
	for i in _catalog.size():
		if _catalog.name_of(i) == piece_id:
			return i
	return -1

## Rotate a cell offset to the nearest 90° quarter-turn around Y. yaw_step is in 45° units (YAW_STEPS=8); odd steps quantise down to the lower quarter (cells can't sit at 45°).
func _rotate_offset(off: Vector3i, yaw_step: int) -> Vector3i:
	var quarters := (yaw_step % BuildGrid.YAW_STEPS) / (BuildGrid.YAW_STEPS / 4)
	var x := off.x
	var z := off.z
	for _i in range(quarters):
		var nx := -z
		var nz := x
		x = nx
		z = nz
	return Vector3i(x, off.y, z)

func _spawn_map_vehicles() -> void:
	var index := 0
	for vs in _map.vehicle_spawns:
		var type := _vehicles_cat.index_of(String(vs["type"]))
		if type < 0:
			push_error("[server] vehicle_spawn unknown type '%s'" % vs["type"]); continue
		var v := Vehicle.make(Vehicle.id_for(index), type, _vehicles_cat.def_of(type), int(vs["team"]), vs["pos"])
		v.heading = float(vs["heading"])
		_sim.world.spawn_vehicle(v)
		index += 1
	print("[server] spawned %d vehicle(s)" % _sim.world.vehicles.size())

## Gunner-seat mounted gun: hit-scan from the turret muzzle along the gunner's aim, reusing the
## lag-comp frame + Hitbox path (FF-off, present rewind to the gunner's view tick). Rate-limited
## by the weapon fire_interval. v1 = anti-infantry only.
func _resolve_vehicle_fires() -> void:
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if not v.alive or v.mounted.is_empty(): continue
		var gunner := 0
		for seat in v.seats.size():
			if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER and int(v.seats[seat]) != 0:
				gunner = int(v.seats[seat]); break
		if gunner == 0 or not _clients.has(gunner): continue
		var inp = _clients[gunner]["last_input"]
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_FIRE) == 0: continue
		var interval := float(v.mounted["fire_interval"])
		if (float(_sim.tick) - float(v.last_mounted_fire_tick)) * SimLoop.DT < interval: continue
		v.last_mounted_fire_tick = _sim.tick
		var gp: Pawn = _sim.world.get_pawn(gunner)
		if gp == null: continue
		var origin := v.turret_muzzle()
		var dir := Combat._forward(v.turret_yaw, gp.pitch)
		var max_range := float(v.mounted["range_m"])
		var view_tick: int = int(inp["view_server_tick"])
		var frame := _lag.rewind(view_tick)
		var candidates: Array = _grid.query(origin, max_range + FIRE_RANGE_MARGIN, _positions)
		var best_t := max_range + 1.0
		var best_victim := 0
		var best_head := false
		for tid in candidates:
			if tid == gunner: continue
			if not frame.has(tid): continue
			var stt = frame[tid]
			if not stt["alive"] or stt["team"] == v.team: continue
			var vcenter: Vector3 = stt["pos"] + Vector3(0.0, Stance.body_height(stt["stance"]) * 0.5, 0.0)
			var to_target: Vector3 = vcenter - origin
			if to_target.length() > max_range: continue
			if to_target.length() > FIRE_CONE_SKIP_RANGE and to_target.normalized().dot(dir) < FIRE_CONE_DOT: continue
			var hit := Hitbox.raycast_pawn(origin, dir, stt["pos"], stt["stance"], max_range)
			if hit["hit"] and hit["t"] < best_t:
				best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]
		if best_victim == 0: continue
		var victim: Pawn = _sim.world.get_pawn(best_victim)
		if victim == null or not victim.alive: continue
		_shots += 1; _hits += 1
		_apply_pawn_damage(best_victim, victim, int(v.mounted["damage"]), best_head, Revive.Source.BULLET, gunner, 0)

func _resolve_fires() -> void:
	for id in _clients:
		var c = _clients[id]
		var inp = c["last_input"]
		if inp == null: continue
		var shooter: Pawn = _sim.world.get_pawn(id)
		if shooter == null or not shooter.alive or shooter.is_downed: continue   # downed = incapacitated, can't fire
		if c["weapon"] == Weapon.RPG:
			c["shot_index"] = 0
			# RPG fires via GADGET_ACTION(GA_RPG_FIRE), not the hit-scan path. RELOAD refills the rocket pool.
			var rpg_max := int(_gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"])
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and int(c["rockets"]) < rpg_max:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(RPG_RELOAD_SECS * TICK_RATE))
				_broadcast_reload_fx(id, int(c["reload_done_tick"]) - _sim.tick)
			continue
		var firing: bool = (inp["buttons"] & InputCommand.BTN_FIRE) != 0
		if not firing:
			c["shot_index"] = 0
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * TICK_RATE))
				_broadcast_reload_fx(id, int(c["reload_done_tick"]) - _sim.tick)
			continue
		var now := float(_sim.tick) * SimLoop.DT
		var ready: bool = now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting: bool = (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		var drop_shoot: bool = Combat.drop_shoot_blocked(shooter.stance, _sim.tick, shooter.last_stance_change_tick)
		var mode: int = int(c.get("fire_mode", Weapon.default_mode(c["weapon"])))
		var burst: int = int(Weapon.get_def(c["weapon"]).get("burst_count", Weapon.DEFAULT_BURST))
		var mode_ok: bool = Weapon.fire_allowed(mode, c["shot_index"], burst)
		var equipping: bool = _sim.tick < int(c.get("swap_locked_until", 0))
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting or drop_shoot or not mode_ok or equipping:
			if drop_shoot:
				_drop_shoot_blocked += 1
			continue
		c["last_fire_time"] = now
		c["ammo"] -= 1
		var shot_index: int = c["shot_index"]
		c["shot_index"] = shot_index + 1
		_shots += 1
		_fire_shot(id, shooter, inp, shot_index)

func _broadcast_shot_fx(shooter_id: int, origin: Vector3, dir: Vector3) -> void:
	# Cosmetic remote-tracer hint. Sent only to HUMAN clients (auto_deploy=false) — bots don't
	# render, and skipping them keeps the fan-out tiny at bot scale. Unreliable (droppable).
	var pkt := Protocol.encode_shot_fx(origin, dir, shooter_id)
	for cid in _clients:
		if cid == shooter_id:
			continue
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)


func _broadcast_reload_fx(reloader_id: int, duration_ticks: int) -> void:
	# Cosmetic remote-reload cue. Sent to human clients except the reloader (they see their own reload
	# via the viewmodel + SELF_STATE). Unreliable (droppable) — a missed cue just skips one reload pose.
	var pkt := Protocol.encode_reload_fx(reloader_id, duration_ticks)
	for cid in _clients:
		if cid == reloader_id:
			continue
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)


const MAX_IMPACT_FX_PER_TICK := 24   # bound the cosmetic-impact fan-out per tick at bot scale
var _impact_fx_this_tick := 0

## Cosmetic bullet-impact puff at world geometry. Sent to ALL human clients (the shooter wants to
## see their own rounds chip the wall too). Unreliable + per-tick capped; bots skipped (don't render).
func _broadcast_impact_fx(pos: Vector3, kind: int) -> void:
	if _impact_fx_this_tick >= MAX_IMPACT_FX_PER_TICK:
		return
	_impact_fx_this_tick += 1
	var pkt := Protocol.encode_impact_fx(pos, kind)
	for cid in _clients:
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)


func _fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = _clients[shooter_id]["weapon"]
	var wdef: Dictionary = _clients[shooter_id]["weapon_def"]
	var prone: bool = shooter.stance == Stance.PRONE
	var supp_deg := Suppress.spread_penalty_deg(shooter.suppression)   # M5.5-P2: incoming fire widens our spread
	# Aim-down-sights tightens spread. Authoritative: honour the bit only when not sprinting (you can't
	# physically ADS mid-sprint), so a client can't claim ADS accuracy while sprint-running.
	var sprinting: bool = (int(inp["buttons"]) & InputCommand.BTN_SPRINT) != 0 and shooter.stance == Stance.STAND
	var aiming: bool = (int(inp["buttons"]) & InputCommand.BTN_AIM) != 0 and not sprinting
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, _sim.tick, shot_index, moving, prone, wdef, supp_deg, aiming)

	# Cosmetic: tell human clients (renderers) about this shot so remote pawns show a tracer.
	_broadcast_shot_fx(shooter_id, ray["origin"], ray["dir"])

	# M5.5-P1: bullets are stepped server-side projectiles. Spawn at the COMMAND tick, then step in
	# PRESENT time (no per-shot lag-comp rewind for bullets — travel time masks latency). The hit is
	# resolved later in _step_projectiles (broadphase + penetration + _apply_pawn_damage + hitmarker).
	var wmv: float = float(wdef["muzzle_velocity"])
	if _projectiles.size() < MAX_LIVE_PROJECTILES:
		# Store the scalars _step_projectiles uses, not the wdef ref — the projectile is conceptually
		# shared with the future M7 client tracer, which has no server def dict (self-contained).
		_projectiles.append({
			"owner": shooter_id, "team": shooter.team, "weapon_id": wid,
			"gravity_scale": float(wdef["gravity_scale"]), "range_m": float(wdef["range_m"]),
			"damage_body": int(wdef["damage_body"]), "headshot_mult": float(wdef["headshot_mult"]),
			"pos": ray["origin"], "vel": Projectile.initial_velocity(ray["dir"], wmv),
			"spawn_tick": _sim.tick, "dist": 0.0, "ttl": Weapon.projectile_ttl_ticks(wid),
		})
		_proj_fired += 1
	else:
		_proj_dropped += 1

# Test seam: spawn a projectile for a known owner/weapon/dir without going through input/loadout.
# Used by tests/projectile_gate_test.gd; never called in production.
func _spawn_projectile_for_test(owner: int, wid: int, pos: Vector3, dir: Vector3) -> void:
	var p: Pawn = _sim.world.get_pawn(owner)
	var wdef: Dictionary = Weapon.get_def(wid)
	_projectiles.append({"owner": owner, "team": (p.team if p else 0), "weapon_id": wid,
		"gravity_scale": float(wdef["gravity_scale"]), "range_m": float(wdef["range_m"]),
		"damage_body": int(wdef["damage_body"]), "headshot_mult": float(wdef["headshot_mult"]),
		"pos": pos, "vel": Projectile.initial_velocity(dir, float(wdef["muzzle_velocity"])),
		"spawn_tick": _sim.tick, "dist": 0.0, "ttl": Weapon.projectile_ttl_ticks(wid)})

# Integrate each live bullet one tick, raycast its per-tick segment against enemy pawns (interest-grid
# broadphase) + the structure store (penetration), and on a confirmed pawn hit apply damage. Models on
# _step_rockets; per-shot `return`s from the old _fire_shot become `continue` (drop one projectile, keep
# iterating the pool). PRESENT-time resolve — no lag-comp rewind for bullets.
## Shortest distance from point `p` to segment a→b (for near-miss suppression).
func _point_seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	var t := clampf((p - a).dot(ab) / denom, 0.0, 1.0) if denom > 0.0 else 0.0
	return p.distance_to(a + ab * t)

func _step_projectiles() -> void:
	_impact_fx_this_tick = 0   # reset the per-tick cosmetic-impact cap
	if _projectiles.is_empty():
		return
	var still: Array = []
	for pr in _projectiles:
		var wid: int = int(pr["weapon_id"])
		var max_range: float = float(pr["range_m"])
		var gscale: float = float(pr["gravity_scale"])
		var old_pos: Vector3 = pr["pos"]
		var s := Projectile.integrate(old_pos, pr["vel"], gscale, SimLoop.DT)
		var nxt: Vector3 = s["pos"]
		var seg: Vector3 = nxt - old_pos
		var seg_len := seg.length()
		var seg_dir: Vector3 = seg / seg_len if seg_len > 0.0001 else Vector3.FORWARD

		# Broad-phase: enemy pawns whose hitbox the segment could cross this tick (current positions
		# + lag-comp margin). Bound the ray test to the segment length (PRESENT-time resolve).
		var candidates: Array = _grid.query(old_pos, seg_len + FIRE_RANGE_MARGIN, _positions)
		var best_t := seg_len + 1.0
		var best_victim := 0
		var best_head := false
		for tid in candidates:
			if tid == int(pr["owner"]): continue
			var tgt: Pawn = _sim.world.get_pawn(tid)
			if tgt == null or not tgt.alive: continue
			if tgt.team == int(pr["team"]): continue
			# Downed pawns are immune (BattleBit-style no finishing): the bullet does no damage and
			# never blocks (passes through to whatever's behind), but show a cosmetic blood impact if
			# the round actually hits the body — feedback that you're firing on someone already down.
			if tgt.is_downed:
				var dhit := Hitbox.raycast_pawn(old_pos, seg_dir, tgt.pos, tgt.stance, seg_len)
				if dhit["hit"]:
					_broadcast_impact_fx(old_pos + seg_dir * float(dhit["t"]), Protocol.IMPACT_FLESH)
				continue
			# M5.5-P2 suppression: a live enemy bullet whose segment passes within SUPPRESS_RADIUS of
			# the pawn raises its suppression (closer = more), whether or not it lands. Measured against
			# the segment (point-to-segment distance) so a fast bullet still suppresses across one tick.
			var miss := _point_seg_dist(tgt.pos, old_pos, nxt)
			if miss < Suppress.SUPPRESS_RADIUS:
				tgt.suppression = Suppress.accrue(tgt.suppression, miss)
				_suppress_events += 1
			var hit := Hitbox.raycast_pawn(old_pos, seg_dir, tgt.pos, tgt.stance, seg_len)
			if hit["hit"] and hit["t"] < best_t:
				best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]

		# Enemy hit damage (incl. headshot/range over total distance flown). Penetration scales it.
		# Reconstruct the minimal def from the projectile's captured scalars so attachment-modified
		# falloff/headshot are preserved without holding a wdef ref.
		var enemy_dmg := 0
		if best_victim != 0:
			# beyond weapon range -> 0 dmg -> bullet consumed silently (range falloff)
			enemy_dmg = Combat.damage_for(wid, best_head, float(pr["dist"]) + best_t,
				{"range_m": float(pr["range_m"]), "damage_body": int(pr["damage_body"]),
				"headshot_mult": float(pr["headshot_mult"])})
		var body_dmg := int(pr["damage_body"])

		# Cover / penetration: a structure strictly nearer than the enemy along THIS segment.
		if _store.count() > 0 and seg_len > 0.0001:
			var march_max: float = best_t if best_victim != 0 else seg_len
			var blocked := _store.march(old_pos, seg_dir, march_max)
			if blocked["hit"] and float(blocked["dist"]) < best_t:
				var block_id := int(blocked["id"])
				var rec: Dictionary = _store.get_record(block_id)
				if rec.is_empty():
					continue   # piece gone (defensive)
				var hit_pt: Vector3 = old_pos + seg_dir * float(blocked["dist"])
				var mat := _catalog.material_of(int(rec["type"]))
				_shots_blocked += 1
				if not PieceCatalog.is_penetrable(mat):
					_damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, BULLET_CARVE_RADIUS)
					_broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: bullet chips the wall
					continue   # stopped by cover — consume the bullet
				# Penetrable: bullet exits at *transmit. Piece is carved geometrically (M11).
				var split := Combat.apply_penetration(body_dmg, enemy_dmg,
					PieceCatalog.absorption_of(mat), PieceCatalog.transmit_of(mat))
				_damage_structure(block_id, PieceCatalog.SRC_BULLET, hit_pt, BULLET_CARVE_RADIUS)
				_broadcast_impact_fx(hit_pt, Protocol.IMPACT_WALL)   # cosmetic: dust where it punches through
				if _store.get_record(block_id).is_empty():
					continue   # 1-pen: piece destroyed by this bullet consumes it
				if best_victim == 0:
					continue   # nothing beyond to hit; bullet passed through but found no pawn
				_pen += 1
				enemy_dmg = int(split["exit_damage"])

		if best_victim != 0 and enemy_dmg > 0:
			var victim: Pawn = _sim.world.get_pawn(best_victim)
			if victim != null and victim.alive:
				_hits += 1
				_proj_hits += 1
				_broadcast_impact_fx(old_pos + seg_dir * best_t, Protocol.IMPACT_FLESH)   # cosmetic blood mist at the hit
				_apply_pawn_damage(best_victim, victim, enemy_dmg, best_head, Revive.Source.BULLET,
					int(pr["owner"]), wid)
				# Hitmarker to the (human, manually-deployed) shooter — lethal = killed or downed.
				var sc: Dictionary = _clients.get(int(pr["owner"]), {})
				if not sc.is_empty() and not sc.get("auto_deploy", true):
					var lethal: bool = (not victim.alive) or victim.is_downed
					_net.send_to(sc["peer"], NetHost.CHANNEL_CONTROL,
						Protocol.encode_hitmarker(best_head, lethal), 0)
			continue   # bullet consumed on a pawn hit

		# Miss this tick: advance state and decide whether the bullet lives on.
		pr["pos"] = nxt
		pr["vel"] = s["vel"]
		pr["dist"] = float(pr["dist"]) + seg_len
		_dbg_last_min_y = minf(_dbg_last_min_y, nxt.y)
		if nxt.y <= 0.0:
			# Cosmetic dirt puff at the ground-impact point (lerp the segment to y=0 for accuracy).
			var gt: float = old_pos.y / (old_pos.y - nxt.y) if old_pos.y > nxt.y else 1.0
			_broadcast_impact_fx(old_pos + (nxt - old_pos) * gt, Protocol.IMPACT_DIRT)
			continue   # hit the ground
		if Projectile.expired(_sim.tick - int(pr["spawn_tick"]), int(pr["ttl"]),
				float(pr["dist"]), max_range):
			continue
		still.append(pr)
	_projectiles = still
	_proj_live_max = maxi(_proj_live_max, _projectiles.size())

func _is_medic(id: int) -> bool:
	return _clients.has(id) and int(_clients[id]["class"]) == Loadout.MEDIC

func _down_pawn(victim: Pawn) -> void:
	victim.is_downed = true
	victim.bleed_health = 0
	victim.bleed_halted = false
	_downed += 1
	# No ticket cost and no KILL event at down — only true death spends a ticket.

func _kill_pawn(vid: int, victim: Pawn, killer_id: int, weapon_id: int, headshot: bool, source: int) -> void:
	var was_downed := victim.is_downed   # true => bleed-out/give-up; recap uses the down-time snapshot
	victim.alive = false
	victim.is_downed = false
	# Vacate any vehicle seat on death, else the per-tick seat-follow drags the pawn back to
	# the seat after it respawns elsewhere (HQ/teammate) — trapping the player in the vehicle.
	if victim.in_vehicle != 0:
		var seated_veh: Vehicle = _sim.world.vehicles.get(victim.in_vehicle)
		if seated_veh != null and victim.seat >= 0 and victim.seat < seated_veh.seats.size():
			seated_veh.seats[victim.seat] = 0
		victim.in_vehicle = 0
		victim.seat = -1
	if _clients[vid].get("auto_deploy", true):
		_clients[vid]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
	else:
		# auto_deploy=false (human): returns to deploy screen, but not before a respawn cooldown
		# (death has weight; the body stays put until they can redeploy).
		_clients[vid]["deploy_ready_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
	_conquest.register_death(victim.team)
	_kills += 1
	if _clients.has(vid):
		_clients[vid]["deaths"] = int(_clients[vid]["deaths"]) + 1
	if _clients.has(killer_id) and killer_id != vid:
		_clients[killer_id]["kills"] = int(_clients[killer_id]["kills"]) + 1
		_clients[killer_id]["score"] = int(_clients[killer_id]["score"]) + KILL_SCORE
	if source == Revive.Source.BLAST:
		_splash_kills += 1
	if _clients.has(vid):
		var c2: Dictionary = _clients[vid]
		var dist: float
		var khp: int
		if was_downed and c2.has("downed_by_hp"):
			# Death after a down (bleed-out/give-up): use the attacker's HP + range captured the
			# moment they downed you — the live attacker may since have died or respawned.
			dist = float(c2.get("downed_by_dist", 0.0))
			khp = int(c2["downed_by_hp"])
		else:
			var killer: Pawn = _sim.world.get_pawn(killer_id)
			dist = victim.pos.distance_to(killer.pos) if killer != null else 0.0
			khp = int(killer.health) if killer != null else 0
		var attackers := DeathRecap.attackers_sorted(c2["dmg_ledger"])
		_net.send_to(c2["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_death_info(killer_id, weapon_id, dist, khp, attackers), ENetPacketPeer.FLAG_RELIABLE)
		c2["dmg_ledger"] = {}
		for k in ["downed_by", "downed_by_weapon", "downed_by_hp", "downed_by_dist"]:
			c2.erase(k)   # consumed by this death
	var ev := Protocol.encode_kill(vid, killer_id, weapon_id, headshot)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, ev, ENetPacketPeer.FLAG_RELIABLE)

## Apply height-based fall damage to any pawn that landed this tick (landed_fall set by SimLoop).
## Routes through the normal damage pipeline; a lethal fall kills outright (Revive.Source.FALL).
func _apply_fall_damage() -> void:
	for id in _clients:
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or not p.alive or p.is_downed:
			continue
		if p.landed_fall <= 0.0:
			continue
		var dmg := Fall.damage_for(p.landed_fall)
		if dmg > 0:
			_apply_pawn_damage(id, p, dmg, false, Revive.Source.FALL, id, 0)

## Single routing path for all pawn damage. A standing pawn is killed outright by a headshot or
## blast (instant-kill bypass) and otherwise downed. DOWNED pawns are immune to weapon damage
## (no finishing, BattleBit-style) — they resolve only via passive bleed-out or a teammate revive.
func _apply_pawn_damage(vid: int, victim: Pawn, dmg: int, headshot: bool, source: int,
		killer_id: int, weapon_id: int) -> void:
	if victim.is_downed:
		return  # immune to damage while downed
	# M5.5-P2 armor: scale body damage by the victim's tier; a HEAVY helmet can downgrade a
	# sub-threshold (finishing) headshot off the instant-kill, routing it through as body damage
	# (DBNO-eligible). Runs before the HP reduction + is_instant_kill routing below.
	if headshot:
		if not Armor.headshot_lethal(victim.armor_class, dmg, victim.health):
			headshot = false
			dmg = int(round(float(dmg) * Armor.body_mult(victim.armor_class)))
	else:
		dmg = int(round(float(dmg) * Armor.body_mult(victim.armor_class)))
	victim.health -= dmg
	if _clients.has(vid):
		var src: Pawn = _sim.world.get_pawn(killer_id)
		var bearing: float = DamageDir.bearing(victim.pos, src.pos) if src != null else 0.0
		_net.send_to(_clients[vid]["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_damage_event(bearing, dmg), 0)
		if killer_id != 0:
			var led: Dictionary = _clients[vid]["dmg_ledger"]
			led[killer_id] = int(led.get(killer_id, 0)) + dmg
	if victim.health > 0:
		return
	victim.health = 0
	if Revive.is_instant_kill(headshot, source):
		_kill_pawn(vid, victim, killer_id, weapon_id, headshot, source)
	else:
		# Remember who downed the pawn (+ their weapon) so a later bleed-out / give-up death
		# credits the attacker, not the victim. (killer_id 0 = no attacker, e.g. fall.)
		if _clients.has(vid) and killer_id != 0:
			var dk: Pawn = _sim.world.get_pawn(killer_id)
			_clients[vid]["downed_by"] = killer_id
			_clients[vid]["downed_by_weapon"] = weapon_id
			# Snapshot the attacker's HP + range AT DOWN TIME — by the time the victim bleeds out
			# the attacker may be dead/respawned, so the live value would read wrong (0 HP).
			_clients[vid]["downed_by_hp"] = int(dk.health) if dk != null else 0
			_clients[vid]["downed_by_dist"] = victim.pos.distance_to(dk.pos) if dk != null else 0.0
		_down_pawn(victim)

func _complete_revive(target_id: int) -> void:
	var p: Pawn = _sim.world.get_pawn(target_id)
	if p == null: return
	p.is_downed = false
	p.health = Revive.REVIVE_HP
	p.bleed_health = 0
	p.bleed_halted = false
	# Fresh start after a revive: clear the damage ledger so a later death's recap reflects the
	# lethal sequence (~one health bar), not damage accumulated across the whole life.
	if _clients.has(target_id):
		_clients[target_id]["dmg_ledger"] = {}
		for k in ["downed_by", "downed_by_weapon", "downed_by_hp", "downed_by_dist"]:
			_clients[target_id].erase(k)
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
	_being_revived = active_targets   # expose to the SELF_STATE send so the downed player sees it
	# Drop accumulated progress for downed targets with no in-range reviver this tick.
	for t in _revive_ticks.keys():
		if not active_targets.has(t):
			_revive_ticks.erase(t)
	# Advance + complete.
	for target_id in active_targets:
		var reviver_id: int = active_targets[target_id]
		_support_links_this_tick.append({"giver": reviver_id, "target": target_id, "kind": SupportLinks.REVIVE})
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
			_support_links_this_tick.append({"giver": gid, "target": target, "kind": SupportLinks.HEAL})
		else:
			_give_ammo(target, int(gdef["active_rate"]))
			_support_links_this_tick.append({"giver": gid, "target": target, "kind": SupportLinks.AMMO})
	for gid in done:
		_giving.erase(gid)

## Latched repair (like active-give): each held engineer near a friendly damaged vehicle restores
## REPAIR_RATE/tick. Unlimited but overheat-gated (no pool). See docs/specs/vehicles.md §6.
func _step_repairs() -> void:
	if _repairing.is_empty():
		return
	var rdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_REPAIR)
	var rate := int(rdef["rate"]); var rng := float(rdef["range"])
	var overheat := int(rdef["overheat_ticks"]); var cool := int(rdef["cooldown_ticks"])
	var done: Array = []
	for eid in _repairing:
		var ep: Pawn = _sim.world.get_pawn(eid)
		if ep == null or not ep.alive or ep.is_downed:
			done.append(eid); continue
		var v := _nearest_friendly_damaged_vehicle(ep, rng)
		var want := v != null
		var st := Gadget.repair_heat_step(int(_repair_heat.get(eid, 0)), int(_repair_cd.get(eid, 0)),
			_sim.tick, want, overheat, cool)
		_repair_heat[eid] = int(st["heat"]); _repair_cd[eid] = int(st["cooldown_until"])
		if int(st["cooldown_until"]) > 0 and want:
			_repair_overheats += 1
		if bool(st["repairing"]) and v != null:
			var before := v.hp
			v.hp = mini(v.max_hp, v.hp + rate)
			_repairs += v.hp - before
			_support_links_this_tick.append({"giver": eid, "target": v.id, "kind": SupportLinks.REPAIR})
	for eid in done:
		_repairing.erase(eid)

func _nearest_friendly_damaged_vehicle(ep: Pawn, rng: float) -> Vehicle:
	var best: Vehicle = null
	var bestd := rng
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if not v.alive or v.team != ep.team or v.hp >= v.max_hp: continue
		var d := ep.pos.distance_to(v.pos)
		if d <= bestd:
			bestd = d; best = v
	return best

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
			# Credit the attacker who downed the pawn (falls back to self if unknown).
			var c = _clients[id]
			_kill_pawn(id, p, int(c.get("downed_by", id)), int(c.get("downed_by_weapon", 0)), false, Revive.Source.BULLET)
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
			p.climbing = false   # clear special-movement state so a pawn that died mid-climb/vault
			p.vaulting = false   # doesn't resume the arc/ladder at its fresh spawn (ghost-vault fix)
			p.bleed_halted = false
			p.bandage_count = Revive.bandage_count_for(_is_medic(id))
			p.grounded = true
			p.fall_peak_y = p.pos.y
			p.landed_fall = 0.0
			c["respawn_tick"] = 0
			_reset_weapon_loadout(c)   # both slots full, fire-mode defaults, back on primary
			c["rockets"] = int(_gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"]) if int(c["weapon"]) == Weapon.RPG else 0
			c["dmg_ledger"] = {}

func _select_spawn(id: int) -> Vector3:
	var c = _clients[id]
	var team: int = c["team"]
	var obj := _objective_for(team)
	var mates: Array = []
	for mid in _squads.members(team, c["squad"]):
		if mid == id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp != null and mp.alive: mates.append(mp.pos)
	var fob_pos = _spawnable_fob_pos(team, int(c["squad"]))
	# fob_disabled is a spawn-DECISION counter: a built+alive FOB exists but was enemy-suppressed.
	# Tally it here (the spawn path), NOT inside _spawnable_fob_pos — that helper is also called every
	# tick per human client by _send_fob_lists/_fob_candidates, which would turn the metric into
	# disabled-render-frames. _fob_built_alive distinguishes "disabled" from "absent/destroyed".
	if fob_pos == null and _fob_built_alive(team, int(c["squad"])):
		_fob_disabled += 1
	var fobs: Array = [fob_pos] if fob_pos != null else []
	var r := SpawnSelect.choose(team, _map, _conquest, mates, obj, fobs)
	if int(r["kind"]) == SpawnSelect.SRC_FOB:
		_fob_spawns += 1
	return r["pos"]

## True if the squad has a completed, not-yet-destroyed FOB structure (regardless of enemy proximity).
func _fob_built_alive(team: int, squad: int) -> bool:
	var rec := _fob_for(team, squad)
	return not rec.is_empty() and bool(rec["built"]) and not _store.get_record(int(rec["id"])).is_empty()

## The squad's FOB world position IFF built + alive + enemy-free; else null. Pure query (no side
## effects) — fob_disabled is tallied by the caller on the spawn-decision path (see _select_spawn).
func _spawnable_fob_pos(team: int, squad: int):
	if not _fob_built_alive(team, squad): return null
	var rec := _fob_for(team, squad)
	var center := BuildGrid.world_of(rec["cell"])
	var enemies: Array = []
	for oid in _clients:
		var op: Pawn = _sim.world.get_pawn(oid)
		if op != null and op.alive and op.team != team:
			enemies.append(op.pos)
	return center if Fob.spawn_enabled(center, enemies) else null

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
	var vstate := _sim.world.vehicle_state_map()
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
		var current_v := {}
		for vid in vstate:
			var vst: VehicleState = vstate[vid]
			if self_pawn.pos.distance_to(vst.pos) <= INTEREST_RADIUS:
				current_v[vid] = vst
		var baseline_seq: int = c["last_acked_seq"]
		var baseline = c["history"].get(baseline_seq)
		if baseline == null:
			baseline = {}; baseline_seq = 0
		var baseline_v = c["history_v"].get(baseline_seq)
		if baseline_v == null:
			baseline_v = {}
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, baseline_seq, c["last_input_tick"], current, baseline, current_v, baseline_v)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)
		var reload_remaining: int = maxi(0, int(c["reload_done_tick"]) - _sim.tick) if c["reloading"] else 0
		# Reliable so the authoritative ammo/reload always reaches the owner — otherwise dropped
		# SELF_STATE packets (lossy links) leave the client predicting phantom ammo it doesn't have.
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_self_state(int(c["ammo"]), bool(c["reloading"]), reload_remaining, int(c["weapon"]), _throwables_for(c), _being_revived.has(id), self_pawn.suppression, clampi(self_pawn.blind_until_tick - _sim.tick, 0, 255), self_pawn.bandage_count, self_pawn.bleed_halted),
			ENetPacketPeer.FLAG_RELIABLE)
		c["history"][seq] = current
		c["history_v"][seq] = current_v
		c["next_seq"] = seq + 1
		var cutoff := seq - MAX_HISTORY
		for s in c["history"].keys():
			if s < cutoff: c["history"].erase(s)
		for s in c["history_v"].keys():
			if s < cutoff: c["history_v"].erase(s)
		_tele.add_bytes(id, bytes.size())

func _broadcast_roster() -> void:
	var rows: Array = []
	for id in _clients:
		var c = _clients[id]
		rows.append({"id": id, "name": String(c.get("name", "P%d" % id)), "team": int(c["team"]),
			"squad": int(c["squad"]), "kills": int(c["kills"]), "deaths": int(c["deaths"]), "score": int(c["score"])})
	var pkt := Protocol.encode_roster(rows)
	for id in _clients:
		_net.send_to(_clients[id]["peer"], NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO: _handle_hello(peer, bytes)
		Protocol.Msg.INPUT: _handle_input(peer, bytes)
		Protocol.Msg.BUILD_REQUEST: _handle_build_request(peer, bytes)
		Protocol.Msg.PLACE_FOB: _handle_place_fob(peer, bytes)
		Protocol.Msg.REMOVE_FOB: _handle_remove_fob(peer)
		Protocol.Msg.BUILD_REMOVE: _handle_build_remove(peer, bytes)
		Protocol.Msg.GRENADE_THROW: _handle_grenade_throw(peer, bytes)
		Protocol.Msg.REVIVE_ACTION: _handle_revive_action(peer, bytes)
		Protocol.Msg.SELF_BANDAGE: _handle_self_bandage(peer, bytes)
		Protocol.Msg.GIVE_UP: _handle_give_up(peer)
		Protocol.Msg.GADGET_ACTION: _handle_gadget_action(peer, bytes)
		Protocol.Msg.VEHICLE_ACTION: _handle_vehicle_action(peer, bytes)
		Protocol.Msg.DEPLOY_REQUEST: _handle_deploy_request(peer, bytes)
		Protocol.Msg.SET_SQUAD: _handle_set_squad(peer, bytes)
		Protocol.Msg.SET_FIRE_MODE: _handle_set_fire_mode(peer, bytes)
		Protocol.Msg.SWAP_WEAPON: _handle_swap_weapon(peer, bytes)
		Protocol.Msg.MELEE: _handle_melee(peer)
		_: pass

func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	var auto_deploy: bool = (r.get_u8() == 1) if r.get_available_bytes() > 0 else true
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
	# Humans never roll ENGINEER (its RPG-primary loadout has no click-fire gun); bots still do.
	var cls := Loadout.random_class() if auto_deploy else Loadout.random_class_no_engineer()
	var wid: int = Loadout.weapon_for(cls)
	# RPG-primary is a bot-fleet thing (1/3 of engineers carry it so the fleet exercises
	# anti-vehicle fire). A human handed an RPG-only loadout has no click-fire gun, which reads
	# as "my weapon is broken" — so humans always keep their class's hit-scan primary.
	if cls == Loadout.ENGINEER and id % 3 == 0 and auto_deploy:
		wid = Weapon.RPG
	# Hand a third of Assault bots the DMR so the fleet exercises the Assault-only marksman path.
	if cls == Loadout.ASSAULT and id % 3 == 0 and auto_deploy:
		wid = Weapon.DMR
	# Destruction-testing convenience (--human-rpg): humans spawn Engineer + RPG so the owner can
	# blow up buildings/structures with the rocket. Overrides the no-engineer-for-humans default.
	if _human_rpg and not auto_deploy:
		cls = Loadout.ENGINEER
		wid = Weapon.RPG
	if not Loadout.can_equip(cls, wid):   # authoritative guard (RPG -> Engineer, DMR -> Assault)
		wid = Loadout.weapon_for(cls)
	var attachments := Loadout.default_attachments()
	var weapon_def := Weapon.effective_def(wid, _attachments.multipliers(attachments))
	var start_rockets := int(_gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"]) if wid == Weapon.RPG else 0
	var squad := _squads.assign(id, team)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "input_buf": InputBuffer.new(), "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {}, "history_v": {},
		"team": team, "squad": squad, "class": cls, "weapon": wid, "weapon_def": weapon_def,
		"rockets": start_rockets, "last_rocket_tick": -100000,
		"ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "fire_mode": Weapon.default_mode(wid), "respawn_tick": 0, "auto_deploy": auto_deploy,
		"active_slot": 0, "swap_locked_until": 0,
		"last_build_tick": -100000, "last_grenade_tick": -100000, "known_regions": {},
		"name": pname, "kills": 0, "deaths": 0, "score": 0, "dmg_ledger": {},
	}
	_build_weapon_slots(_clients[id])
	var p := _sim.world.spawn(id)
	p.team = team
	p.squad = squad
	p.pos = _select_spawn(id)
	p.armor_class = Loadout.armor_for(cls)   # M5.5-P2: tier is class-derived, immutable per life
	p.bandage_count = Revive.bandage_count_for(cls == Loadout.MEDIC)
	if not auto_deploy:
		p.alive = false   # held un-deployed until DEPLOY_REQUEST (respawn_tick stays 0)
	# Tell the client which map to render (its roads/points/bases come from its local MapDef) so it
	# never has to be launched with a matching --map. Send the file basename, not the display name.
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE, cls, _map_path.get_file().get_basename()), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d squad=%d class=%d — %d peers" % [id, pname, team, squad, cls, _clients.size()])

func _squad_candidates(req_id: int, team: int, squad_id: int) -> Array:
	var out: Array = []
	for mid in _squads.members(team, squad_id):
		if mid == req_id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp == null: continue
		out.append({"id": mid, "pos": mp.pos, "team": mp.team, "alive": mp.alive, "downed": mp.is_downed})
	return out

func _vehicle_candidates(team: int) -> Array:
	var out: Array = []
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if v == null or v.team != team or not v.alive: continue
		out.append({"slot": vid - Vehicle.ID_BASE, "pos": v.pos, "team": v.team, "free_seats": v.seat_count() - v.occupant_ids().size()})
	return out

## M12-P3: one entry per built FOB owned by a squad on `team` (enabled = currently spawnable).
func _fob_candidates(team: int) -> Array:
	var out: Array = []
	for key in _fobs:
		var rec: Dictionary = _fobs[key]
		if int(rec["team"]) != team or not bool(rec["built"]): continue
		var pos = _spawnable_fob_pos(team, int(rec["squad"]))
		out.append({"squad": int(rec["squad"]), "pos": BuildGrid.world_of(rec["cell"]),
			"enabled": pos != null})
	return out

func _throwables_for(c: Dictionary) -> Array:
	var ready := 1 if _sim.tick - int(c["last_grenade_tick"]) >= GRENADE_COOLDOWN_TICKS else 0
	var list: Array = [{"kind": Grenade.FRAG, "count": ready}, {"kind": Grenade.SMOKE, "count": ready}]
	if int(c["weapon"]) == Weapon.RPG:
		list.append({"kind": 100, "count": int(c["rockets"])})   # kind 100 = RPG (UI-only tag; M5.5 formalizes)
	return list

func _handle_deploy_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or p.alive: return    # already deployed
	if _sim.tick < int(c.get("deploy_ready_tick", 0)): return   # respawn cooldown not elapsed
	var ref := int(Protocol.decode_deploy_request(bytes)["spawn_ref"])
	var mates := _squad_candidates(id, int(c["team"]), int(c["squad"]))
	var vehs := _vehicle_candidates(int(c["team"]))
	var fobs := _fob_candidates(int(c["team"]))
	if not DeploySpawn.is_valid(int(c["team"]), ref, _map, _conquest, mates, vehs, fobs): return
	var dpos := DeploySpawn.resolve(int(c["team"]), ref, _map, _conquest, mates, vehs, fobs)
	if ref >= DeploySpawn.FOB_BASE: _fob_spawns += 1
	p.pos = dpos
	p.velocity = Vector3.ZERO
	p.health = 100
	p.alive = true
	p.stamina = Pawn.STAMINA_MAX
	p.is_downed = false
	p.climbing = false
	p.vaulting = false
	p.in_vehicle = 0   # defensive: never deploy still bound to a seat
	p.seat = -1
	p.grounded = true
	p.fall_peak_y = p.pos.y
	p.landed_fall = 0.0
	_reset_weapon_loadout(c)   # both slots full, fire-mode defaults, back on primary
	c["rockets"] = int(_gadgets.def_of_kind(Gadget.KIND_RPG)["ammo"]) if int(c["weapon"]) == Weapon.RPG else 0   # refill rockets on (re)deploy, not just respawn (reads restored primary weapon)
	c["respawn_tick"] = 0
	c["dmg_ledger"] = {}

func _handle_set_squad(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var team: int = int(c["team"])
	var target: int = int(Protocol.decode_set_squad(bytes)["squad"])
	if not _squads.join(id, team, target): return   # full -> ignore
	c["squad"] = target
	var p: Pawn = _sim.world.get_pawn(id)
	if p != null:
		p.squad = target   # replicated via EntityState.squad -> roster/squad-list update next ROSTER

func _handle_set_fire_mode(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var m := Protocol.decode_set_fire_mode(bytes)
	if Weapon.mode_allowed(int(_clients[id]["weapon"]), m):
		_clients[id]["fire_mode"] = m

## Build the two weapon slots. Slot 0 = snapshot of the current (primary) flat fields.
## Slot 1 = a fresh secondary (sidearm) at full ammo, default fire-mode.
func _build_weapon_slots(c: Dictionary) -> void:
	var primary := {}
	for f in _SLOT_FIELDS: primary[f] = c[f]
	var swid: int = Loadout.secondary_for(int(c["class"]))
	var sdef: Dictionary = Weapon.effective_def(swid, {})   # secondary has no attachments in v1
	var secondary := {
		"weapon": swid, "weapon_def": sdef,
		"ammo": int(Weapon.get_def(swid)["mag_size"]),
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "fire_mode": Weapon.default_mode(swid),
	}
	c["slots"] = [primary, secondary]
	c["active_slot"] = 0

func _save_active_slot(c: Dictionary) -> void:
	var slot: Dictionary = c["slots"][int(c["active_slot"])]
	for f in _SLOT_FIELDS: slot[f] = c[f]

func _load_active_slot(c: Dictionary) -> void:
	var slot: Dictionary = c["slots"][int(c["active_slot"])]
	for f in _SLOT_FIELDS: c[f] = slot[f]

func _swap_weapon(id: int, target: int) -> void:
	if not _clients.has(id): return
	var c: Dictionary = _clients[id]
	if not c.has("slots"): return   # slots built in _handle_hello; guard parity with _reset_weapon_loadout
	if target < 0 or target > 1 or target == int(c["active_slot"]): return
	if _sim.tick < int(c["swap_locked_until"]): return
	_save_active_slot(c)               # freeze current slot's live state
	c["active_slot"] = target
	_load_active_slot(c)               # hydrate flat fields from the target slot
	c["swap_locked_until"] = _sim.tick + WEAPON_SWAP_TICKS
	_swaps += 1

## On (re)spawn/deploy: restore a fresh weapon loadout — both slots full ammo, fire-mode defaults,
## back on the primary. Preserves each slot's weapon identity (set at connect; never changes after).
func _reset_weapon_loadout(c: Dictionary) -> void:
	if not c.has("slots"):
		return  # safety: client without slots (shouldn't happen post-_build_weapon_slots)
	for slot in c["slots"]:
		var swid: int = int(slot["weapon"])
		slot["ammo"] = int(Weapon.get_def(swid)["mag_size"])
		slot["reloading"] = false
		slot["reload_done_tick"] = 0
		slot["last_fire_time"] = -999.0
		slot["shot_index"] = 0
		slot["fire_mode"] = Weapon.default_mode(swid)
	c["active_slot"] = 0
	c["swap_locked_until"] = 0
	_load_active_slot(c)   # hydrate flat fields from the (now primary) active slot

func _handle_swap_weapon(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	_swap_weapon(id, Protocol.decode_swap_weapon(bytes))

func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	# Enqueue the bundle's frames (dedup of already-seen copies happens in the buffer); they drain
	# one-per-tick in _step_movement. Redundant frames from earlier packets are how a dropped packet
	# is recovered without staling the server's view of the player.
	c["input_buf"].ingest(d["frames"])
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack: c["history"].erase(s)
		for s in c["history_v"].keys():
			if s < ack: c["history_v"].erase(s)

func _handle_build_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var d := Protocol.decode_build_request(bytes)
	var type: int = d["type"]
	if type < 0 or type >= _catalog.size(): return
	if int(d["yaw"]) < 0 or int(d["yaw"]) >= BuildGrid.YAW_STEPS: return   # reject malformed/out-of-range yaw (map path validates; player path did not)
	var cell: Vector3i = d["cell"]
	var v := _store.validate_place(cell, p.pos, _sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if _catalog.is_structural(type): return   # players build only fortifications, not building pieces
	if _sites.occupied(cell): return          # already a site there
	# Per-player SITE cap: recycle the oldest unfinished site.
	if _sites.owner_count(id) >= MAX_SITES_PER_PLAYER:
		var oldid := _sites.oldest_id(id)
		if oldid != 0:
			var ocell: Vector3i = _sites.get_site(oldid)["cell"]
			_sites.remove(oldid)
			_emit_structure_delta(Protocol.OP_REMOVE, {"id": oldid}, ocell)
	var sid := _next_struct_id
	_next_struct_id += 1
	c["last_build_tick"] = _sim.tick
	var site := {"id": sid, "owner": id, "team": p.team, "type": type, "cell": cell, "yaw": int(d["yaw"]),
		"build_progress": 0.0, "build_cost": _catalog.build_cost_of(type),
		"min_builders": _catalog.min_builders_of(type), "last_work_tick": _sim.tick}
	_sites.add(site)
	_builds += 1
	_emit_structure_delta(Protocol.OP_PLACE, _site_wire_record(site), cell)

## Wire record for an under-construction site: StructureStore record shape + the M12-P2 fields.
func _site_wire_record(site: Dictionary) -> Dictionary:
	return {"id": site["id"], "type": site["type"], "cell": site["cell"], "yaw": site["yaw"],
		"chunks": ChunkMask.full_mask(_catalog.chunk_grid_of(int(site["type"]))),
		"building_id": 0, "owner": site["owner"],
		"under_construction": 1, "build_progress": int(site["build_progress"])}

func _emit_structure_progress(id: int, progress: int, cell: Vector3i) -> void:
	var region := _store.region_of(cell)
	var bytes := Protocol.encode_structure_progress(id, progress)
	for cid in _clients:
		if _clients[cid]["known_regions"].has(region):
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## M12-P3 FOB registry helpers.
func _fob_key(team: int, squad: int) -> String:
	return "%d:%d" % [team, squad]

func _fob_for(team: int, squad: int) -> Dictionary:
	return _fobs.get(_fob_key(team, squad), {})

func _fob_type_index() -> int:
	for i in _catalog.size():
		if _catalog.name_of(i) == "fob":
			return i
	return -1

## M12-P3: squad leader places a FOB build site. Leader-only, one-per-squad (replace), CP/base
## exclusion, then reuses the M12-P2 cooperative build path (promotes to a bunker on completion).
func _handle_place_fob(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var team: int = int(c["team"])
	var squad: int = int(c["squad"])
	if _squads.leader_of(team, squad) != id: return    # leader-only (authoritative)
	var d := Protocol.decode_place_fob(bytes)
	if int(d["yaw"]) < 0 or int(d["yaw"]) >= BuildGrid.YAW_STEPS: return
	var cell: Vector3i = d["cell"]
	var center := BuildGrid.world_of(cell)
	if not Fob.placement_ok(center, team, _map, _conquest): return
	var v := _store.validate_place(cell, p.pos, _sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if _sites.occupied(cell): return
	var fob_type := _fob_type_index()
	if fob_type < 0: return
	# One FOB per squad: drop the existing site/structure first.
	_remove_squad_fob(team, squad)
	var sid := _next_struct_id
	_next_struct_id += 1
	c["last_build_tick"] = _sim.tick
	var site := {"id": sid, "owner": id, "team": team, "type": fob_type, "cell": cell, "yaw": int(d["yaw"]),
		"build_progress": 0.0, "build_cost": _catalog.build_cost_of(fob_type),
		"min_builders": _catalog.min_builders_of(fob_type), "last_work_tick": _sim.tick}
	_sites.add(site)
	_fobs[_fob_key(team, squad)] = {"squad": squad, "team": team, "id": sid, "cell": cell, "built": false}
	_emit_structure_delta(Protocol.OP_PLACE, _site_wire_record(site), cell)

func _handle_remove_fob(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var team: int = int(c["team"]); var squad: int = int(c["squad"])
	if _squads.leader_of(team, squad) != id: return
	_remove_squad_fob(team, squad)

## Remove a squad's FOB entity (under-construction site OR completed structure) + registry record.
func _remove_squad_fob(team: int, squad: int) -> void:
	var rec := _fob_for(team, squad)
	if rec.is_empty(): return
	var fid := int(rec["id"])
	var cell: Vector3i = rec["cell"]
	if _sites.get_site(fid).is_empty() == false:
		_sites.remove(fid)
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": fid}, cell)
	elif _store.get_record(fid).is_empty() == false:
		_store.remove(fid)
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": fid}, cell)
	_fobs.erase(_fob_key(team, squad))

## M12-P3: detect FOB lifecycle transitions against the live stores (robust to every removal path):
## site->built (tally fobs_built), built->gone (tally fobs_destroyed), site->gone-before-built (decay).
func _reconcile_fobs() -> void:
	if _fobs.is_empty(): return
	var drop: Array = []
	for key in _fobs:
		var rec: Dictionary = _fobs[key]
		var fid := int(rec["id"])
		if not bool(rec["built"]):
			if not _store.get_record(fid).is_empty():
				rec["built"] = true
				_fobs_built += 1
			elif _sites.get_site(fid).is_empty():
				drop.append(key)   # site decayed/removed before completing
		else:
			if _store.get_record(fid).is_empty():
				_fobs_destroyed += 1
				drop.append(key)   # bunker destroyed via M4 path / dismantle / recycle
	for key in drop:
		_fobs.erase(key)

## M12-P2: advance build sites from eligible shovellers; complete -> promote to StructureStore;
## decay abandoned sites; then repair/dismantle finished structures for the remaining shovellers.
func _step_build_sites() -> void:
	# Pawns holding BTN_SHOVEL this tick.
	var shov := {}
	for cid in _clients:
		var inp = _clients[cid]["last_input"]
		if inp == null or (int(inp["buttons"]) & InputCommand.BTN_SHOVEL) == 0:
			continue
		var pp: Pawn = _sim.world.get_pawn(cid)
		if pp == null or not pp.alive or pp.is_downed:
			continue
		shov[cid] = {"pos": pp.pos, "fwd": Combat._forward(pp.yaw, pp.pitch), "team": pp.team}
	if _sites.count() == 0 and shov.is_empty():
		return
	var built: Array = []
	var decayed: Array = []
	var busy := {}   # cid -> true: contributed to a site this tick (skip for structure-shovel)
	for id in _sites.ids():
		var s: Dictionary = _sites.get_site(id)
		var center := BuildGrid.world_of(s["cell"])
		var n := 0
		for cid in shov:
			var b = shov[cid]
			if int(b["team"]) != int(s["team"]):
				continue
			if BuildSite.eligible(b["pos"], b["fwd"], center):
				n += 1
				busy[cid] = true
		if n <= 0:
			if BuildSite.decayed(_sim.tick, int(s["last_work_tick"])):
				decayed.append(id)
			continue
		if n < int(s["min_builders"]):
			_build_blocked_solo += 1
			continue
		var before := float(s["build_progress"])
		var after := BuildSite.progress_step(before, int(s["build_cost"]), n, int(s["min_builders"]), SimLoop.DT)
		s["build_progress"] = after
		s["last_work_tick"] = _sim.tick
		if int(after / 6.0) != int(before / 6.0):
			_emit_structure_progress(int(id), int(after), s["cell"])
		if BuildSite.is_complete(after, int(s["build_cost"])):
			built.append(id)
	for id in built:
		_complete_site(int(id))
	for id in decayed:
		var dcell: Vector3i = _sites.get_site(int(id))["cell"]
		_sites.remove(int(id))
		_emit_structure_delta(Protocol.OP_REMOVE, {"id": int(id)}, dcell)
	_step_shovel_structures(shov, busy)
	_reconcile_fobs()   # M12-P3: detect FOB site->built / built->destroyed / pre-build decay

func _complete_site(id: int) -> void:
	var s: Dictionary = _sites.get_site(id)
	if s.is_empty():
		return
	_sites.remove(id)
	# Cap finished pieces per owner (recycle oldest), then promote into the real structure store.
	if _store.owner_count(int(s["owner"])) >= StructureStore.MAX_PIECES_PER_PLAYER:
		var oldp := _store.oldest_id(int(s["owner"]))
		if oldp != 0:
			var oc := _cell_of_struct(oldp)
			_store.recycle_oldest(int(s["owner"]))
			_emit_structure_delta(Protocol.OP_REMOVE, {"id": oldp}, oc)
	var rec := _store.place(id, int(s["type"]), s["cell"], int(s["yaw"]), int(s["owner"]))
	if rec.is_empty():
		return   # lost the cell race
	var wire := rec.duplicate()
	wire["under_construction"] = 0
	wire["build_progress"] = int(s["build_cost"])
	_emit_structure_delta(Protocol.OP_PLACE, wire, s["cell"])
	if int(s["min_builders"]) >= 2:
		_built_large += 1
	else:
		_built_small += 1

## Shovellers not busy building a site repair a friendly / dismantle an enemy finished structure they
## are aiming at within reach. Reuses the M4 melee damage path (dismantle) + repair_chunks (repair).
func _step_shovel_structures(shov: Dictionary, busy: Dictionary) -> void:
	for cid in shov:
		if busy.has(cid):
			continue
		var b = shov[cid]
		var hit := _store.march(b["pos"], b["fwd"], BuildSite.SHOVEL_RANGE)
		if not hit["hit"]:
			continue
		var sidx := int(hit["id"])
		var rec := _store.get_record(sidx)
		if rec.is_empty():
			continue
		var impact: Vector3 = (b["pos"] as Vector3) + (b["fwd"] as Vector3).normalized() * float(hit["dist"])
		var op: Pawn = _sim.world.get_pawn(int(rec["owner"]))
		var struct_team := op.team if op != null else int(b["team"])
		if int(b["team"]) == struct_team:
			var rep := _store.repair_chunks(sidx, impact, 0.9)
			if rep["changed"]:
				_repaired += 1
				_emit_structure_delta(Protocol.OP_CHUNK, {"id": sidx, "mask": int(rep["mask"])}, rec["cell"])
		else:
			if not _catalog.takes_damage(int(rec["type"]), PieceCatalog.SRC_MELEE):
				continue
			var dmg := _store.damage_chunks(sidx, PieceCatalog.SRC_MELEE, impact, 0.6)
			if dmg["destroyed"]:
				_dismantled += 1
				_pending_removes.append({"id": sidx, "cell": rec["cell"]})
			elif dmg["holed"]:
				_dmg_touched[sidx] = true

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
	var gtype := int(d["type"])
	if gtype < Grenade.FRAG or gtype > Grenade.IMPACT:
		gtype = Grenade.FRAG   # reject unknown throwable ids (default to frag)
	_grenades.append({
		"owner": id, "team": p.team, "type": gtype,
		"pos": p.eye_position(), "vel": Grenade.launch_velocity(dir),
		"detonate_tick": _sim.tick + GRENADE_FUSE_TICKS,
	})
	# Cosmetic: let other human clients see the grenade arc through the air (FRAG/SMOKE only — IMPACT
	# isn't in a human loadout and detonates on contact). The thrower renders their own locally.
	if gtype == Grenade.FRAG or gtype == Grenade.SMOKE:
		_broadcast_grenade_fx(id, p.eye_position(), dir.normalized(), gtype)

func _handle_melee(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	_resolve_melee(id)

## Melee swing (M5.5-P3). Knife (all classes): the nearest enemy in the frontal reach cone takes
## MELEE_DAMAGE, or an instant kill if struck within the rear arc (back-stab). Cooldown-gated per
## client. (The Engineer sledgehammer structure branch is added in Task 4.)
func _resolve_melee(id: int) -> void:
	var c = _clients[id]
	if _sim.tick < int(c.get("melee_ready_tick", 0)): return
	c["melee_ready_tick"] = _sim.tick + MELEE_COOLDOWN_TICKS
	var atk: Pawn = _sim.world.get_pawn(id)
	if atk == null or not atk.alive or atk.is_downed: return
	var melee_damage := MELEE_DAMAGE
	# Engineer sledgehammer: demolish the structure cell under the crosshair first (heavy carve via
	# SRC_MELEE). With no structure in reach it bonks a pawn for SLEDGE_PAWN_DAMAGE (knife path below).
	if Loadout.has_sledgehammer(int(c.get("class", -1))):
		melee_damage = SLEDGE_PAWN_DAMAGE
		if _store != null and _store.count() > 0:
			var dir := Combat._forward(atk.yaw, atk.pitch)
			var m := _store.march(atk.eye_position(), dir, Melee.MELEE_RANGE)
			if bool(m["hit"]):
				var impact: Vector3 = atk.eye_position() + dir * float(m["dist"])
				_damage_structure(int(m["id"]), PieceCatalog.SRC_MELEE, impact, SLEDGE_STRUCT_RADIUS)
				_sledge_hits += 1
				return
	var enemies: Array = []
	for tid in _sim.world.pawns:
		var v: Pawn = _sim.world.pawns[tid]
		if v != null and v.alive and not v.is_downed and v.team != atk.team:
			enemies.append({"id": tid, "pos": v.pos, "team": v.team})
	var vid := Melee.best_target({"pos": atk.pos, "yaw": atk.yaw, "team": atk.team}, enemies)
	if vid == 0: return
	var victim: Pawn = _sim.world.get_pawn(vid)
	var weapon_id := int(c.get("weapon", 0))
	if Melee.is_backstab(victim.yaw, atk.pos - victim.pos):
		# Rear-arc back-stab = instant kill: headshot=true routes through Revive.is_instant_kill,
		# bypassing DBNO (same path the M4.5 head/blast instant-kill uses).
		_apply_pawn_damage(vid, victim, 100000, true, Revive.Source.BULLET, id, weapon_id)
		_backstabs += 1
	else:
		_apply_pawn_damage(vid, victim, melee_damage, false, Revive.Source.BULLET, id, weapon_id)
	_melees += 1

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
		Protocol.GA_REPAIR_START: _repairing[id] = true
		Protocol.GA_REPAIR_STOP: _repairing.erase(id)
		_: pass

func _handle_vehicle_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null: return
	var d := Protocol.decode_vehicle_action(bytes)
	match int(d["action"]):
		Protocol.VA_ENTER: _vehicle_enter(id, p, int(d["vehicle_id"]), int(d["seat_hint"]))
		Protocol.VA_EXIT: _vehicle_exit(id, p)
		_: pass

func _vehicle_enter(id: int, p: Pawn, vid: int, seat_hint: int) -> void:
	var v: Vehicle = _sim.world.vehicles.get(vid)
	if v == null: return
	if not Vehicle.can_enter(v, p, p.pos.distance_to(v.pos), ENTER_RANGE): return
	var seat := v.free_seat(seat_hint)
	if seat < 0: return
	v.seats[seat] = id
	p.in_vehicle = vid
	p.seat = seat
	_enters += 1
	_transport_origin[id] = v.pos   # for the transport-distance gate metric (Task 16)

func _vehicle_exit(id: int, p: Pawn) -> void:
	if p.in_vehicle == 0: return
	var v: Vehicle = _sim.world.vehicles.get(p.in_vehicle)
	if v != null:
		if p.seat >= 0 and p.seat < v.seats.size(): v.seats[p.seat] = 0
		p.pos = _safe_exit_pos(v)
	p.in_vehicle = 0
	p.seat = -1
	_exits += 1
	_transport_origin.erase(id)

## Pick a dismount position clear of structures so a player doesn't get spat out inside a wall (and
## stuck). Tries the configured exit side first, then the other sides around the hull, then falls back.
func _safe_exit_pos(v: Vehicle) -> Vector3:
	var dist: float = Vector3(v.exit_offset.x, 0.0, v.exit_offset.z).length()
	if dist < 0.5:
		dist = 3.0
	var locals: Array = [v.exit_offset, Vector3(-dist, 0, 0), Vector3(dist, 0, 0),
		Vector3(0, 0, -dist), Vector3(0, 0, dist), Vector3(-dist, 0, -dist) * 0.7071,
		Vector3(dist, 0, -dist) * 0.7071]
	for off: Vector3 in locals:
		var cand: Vector3 = v.pos + Vehicle.rotate_yaw(off, v.heading)
		cand.y = maxf(0.0, cand.y)
		if _store == null or _store.resolve_movement(v.pos, cand).distance_to(cand) < 0.3:
			return cand   # reachable from the hull centre without clipping a structure -> clear
	var fb: Vector3 = v.pos + Vehicle.rotate_yaw(v.exit_offset, v.heading)
	fb.y = maxf(0.0, fb.y)
	return fb

func _track_transport_distance() -> void:
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if not v.alive: continue
		for occ in v.occupant_ids():
			if _transport_origin.has(occ):
				var dist: float = (_transport_origin[occ] as Vector3).distance_to(v.pos)
				_transport_max = maxf(_transport_max, dist)

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
	_rockets.append({"owner": id, "team": p.team, "pos": p.eye_position(), "vel": dir.normalized() * float(rdef["rocket_speed"])})
	# Cosmetic: tell other humans a rocket launched so they render it flying. The shooter renders
	# its own immediately (client-side, no RTT wait) — mirrors the gunfire tracer split.
	_broadcast_rocket_fx(id, p.eye_position(), dir.normalized())

func _broadcast_rocket_fx(shooter_id: int, origin: Vector3, dir: Vector3) -> void:
	var pkt := Protocol.encode_rocket_fx(origin, dir)
	for cid in _clients:
		if cid == shooter_id:
			continue
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)

## Authoritative deployed-gadget list (C4/mines/bags) for human clients to render. Rebuilt from the
## live stores each tick and sent (reliably) only when it CHANGES, plus a ~1 Hz heartbeat while
## non-empty so a late-joining human catches up. Skipped entirely when no human is connected.
func _broadcast_gadget_list() -> void:
	var has_human := false
	for cid in _clients:
		if not bool(_clients[cid].get("auto_deploy", true)):
			has_human = true
			break
	if not has_human:
		return
	var list := GadgetList.build(_c4, _mines, _bags)
	var pkt := Protocol.encode_gadget_list(list)
	var changed := pkt != _gadget_pkt_sent
	var heartbeat := list.size() > 0 and _sim.tick - _gadget_hb_tick >= GADGET_HEARTBEAT_TICKS
	if not changed and not heartbeat:
		return
	_gadget_pkt_sent = pkt
	_gadget_hb_tick = _sim.tick
	for cid in _clients:
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

## Active support links (heal/ammo/repair/revive) for human clients to draw a beam + target aura.
## Same shape as the gadget list: rebuilt each tick from what the support steps actually acted on,
## sent reliably only when it CHANGES, plus a ~1 Hz heartbeat while non-empty for late joiners.
## Skipped entirely when no human is connected.
func _broadcast_support_list() -> void:
	var has_human := false
	for cid in _clients:
		if not bool(_clients[cid].get("auto_deploy", true)):
			has_human = true
			break
	if not has_human:
		return
	var list := SupportLinks.build(_support_links_this_tick)
	var pkt := Protocol.encode_support_list(list)
	var changed := pkt != _support_pkt_sent
	var heartbeat := list.size() > 0 and _sim.tick - _support_hb_tick >= GADGET_HEARTBEAT_TICKS
	if not changed and not heartbeat:
		return
	_support_pkt_sent = pkt
	_support_hb_tick = _sim.tick
	for cid in _clients:
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

## M12-P3: per-team FOB list (squad/structure_id/under_construction/enabled) for human clients to
## render. Bots (auto_deploy) are skipped → zero cost in the headless gate.
func _send_fob_lists() -> void:
	for cid in _clients:
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)): continue   # bots don't render; skip (zero gate cost)
		var team: int = int(c["team"])
		var list: Array = []
		for key in _fobs:
			var rec: Dictionary = _fobs[key]
			if int(rec["team"]) != team: continue
			var built: bool = bool(rec["built"])
			var enabled := false
			if built:
				enabled = _spawnable_fob_pos(team, int(rec["squad"])) != null
			list.append({"squad": int(rec["squad"]), "structure_id": int(rec["id"]),
				"under_construction": 0 if built else 1, "enabled": 1 if enabled else 0})
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, Protocol.encode_fob_list(list), ENetPacketPeer.FLAG_RELIABLE)

## Cosmetic remote thrown-grenade hint. Sent only to HUMAN clients, excluding the thrower (who already
## arcs their own grenade from client_main). Unreliable/droppable, like the other *_FX broadcasts.
func _broadcast_grenade_fx(thrower_id: int, origin: Vector3, dir: Vector3, kind: int) -> void:
	var pkt := Protocol.encode_grenade_fx(origin, dir, kind)
	for cid in _clients:
		if cid == thrower_id:
			continue
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)

func _place_c4(id: int, p: Pawn, pos: Vector3) -> void:
	if Loadout.gadget_for_player(int(_clients[id]["class"]), id) != Loadout.GADGET_C4: return
	var cdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_C4)
	var owned: Array = _c4.get(id, [])
	if owned.size() >= int(cdef["max_active"]): return
	if p.pos.distance_to(pos) > StructureStore.BUILD_RANGE: return   # within reach
	owned.append({"pos": pos, "cell": BuildGrid.cell_of(Vector3(pos.x, 0.0, pos.z))})
	_c4[id] = owned

func _place_mine(id: int, p: Pawn, pos: Vector3, facing: Vector3) -> void:
	if Loadout.gadget_for_player(int(_clients[id]["class"]), id) != Loadout.GADGET_MINE: return
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
			int(cdef["struct_damage"]), float(cdef["struct_radius"]), C4_VEHICLE_DMG)
	_c4.erase(id)

## Drop any placed C4 whose ground cell matches a just-destroyed structure cell (spec §"C4").
func _remove_c4_on_cell(cell: Vector3i) -> void:
	for owner in _c4:
		var kept: Array = []
		for c4 in _c4[owner]:
			if c4["cell"] != cell:
				kept.append(c4)
		_c4[owner] = kept

## A DOWNED player chooses to skip the bleed-out and die now (BattleBit give-up) -> true death,
## spends a ticket, returns them to the deploy screen.
func _handle_give_up(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive or not p.is_downed: return
	var c = _clients[id]
	_kill_pawn(id, p, int(c.get("downed_by", id)), int(c.get("downed_by_weapon", 0)), false, Revive.Source.BULLET)
	_bleedouts += 1

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
		# Impact grenades detonate on first contact (structure march, ground, or an enemy pawn at
		# point-blank) instead of waiting for the fuse. The fuse remains a flight-time safety net.
		if Grenade.is_contact_fuse(int(g["type"])):
			if _step_impact(g):
				continue
			still.append(g)
			continue
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

## One integration step for an impact grenade. Detonates (frag blast via _detonate) on the first
## contact: ground, a structure crossed this step, or an enemy pawn within IMPACT_CONTACT_RADIUS.
## Returns true if it detonated (caller drops it from the pool); false if it is still in flight.
func _step_impact(g: Dictionary) -> bool:
	var s := Grenade.integrate(g["pos"], g["vel"], SimLoop.DT)
	var seg: Vector3 = (s["pos"] as Vector3) - (g["pos"] as Vector3)
	var seg_len := seg.length()
	var struck: bool = s["pos"].y <= 0.0
	if not struck and _store != null and _store.count() > 0 and seg_len > 0.0001:
		if bool(_store.march(g["pos"], seg / seg_len, seg_len)["hit"]):
			struck = true
	if not struck:
		var team := int(g["team"])
		for pid in _sim.world.pawns:
			var v: Pawn = _sim.world.pawns[pid]
			if not v.alive or v.team == team:
				continue
			if v.pos.distance_to(s["pos"]) <= IMPACT_CONTACT_RADIUS:
				struck = true
				break
	if struck:
		if s["pos"].y < 0.0:
			s["pos"].y = 0.0
		g["pos"] = s["pos"]
		_impacts += 1
		_detonate(g)
		return true
	g["pos"] = s["pos"]; g["vel"] = s["vel"]
	return false

## Generalized blast: structure damage (cell radius) + pawn splash (sphere, current positions,
## FF-off incl. owner). Shared by frag grenades, RPG, C4, and mines. `source` tags the kill
## (BLAST). Returns the number of pawns that took damage (for kill/trigger bookkeeping).
func _blast_at(center: Vector3, owner: int, team: int, pawn_dmg: int, pawn_radius: float,
		struct_dmg: int, struct_radius: float, veh_dmg: int = 0) -> int:
	if struct_dmg > 0 and struct_radius > 0.0:
		for sid in _store.ids_in_radius(center, struct_radius):
			_damage_structure(sid, PieceCatalog.SRC_EXPLOSIVE, center, struct_radius)
	var hits := 0
	for pid in _sim.world.pawns:
		if pid == owner: continue
		var victim: Pawn = _sim.world.pawns[pid]
		if not victim.alive or victim.team == team: continue
		var pd := Grenade.falloff_damage(center, victim.pos, pawn_dmg, pawn_radius)
		if pd <= 0: continue
		_apply_pawn_damage(pid, victim, pd, false, Revive.Source.BLAST, owner, 0)
		hits += 1
	if veh_dmg > 0:
		for vid in _sim.world.vehicles:
			var v: Vehicle = _sim.world.vehicles[vid]
			if not v.alive or v.team == team:
				continue
			var vd := Grenade.falloff_damage(center, v.pos, veh_dmg, pawn_radius)
			if vd > 0:
				_damage_vehicle(vid, v, vd, owner)
	return hits

func _damage_vehicle(vid: int, v: Vehicle, amount: int, killer_id: int) -> void:
	v.hp -= amount
	if v.hp <= 0:
		v.hp = 0
		_destroy_vehicle(vid, v, killer_id)

func _destroy_vehicle(vid: int, v: Vehicle, killer_id: int) -> void:
	_veh_destroyed += 1
	for occ in v.occupant_ids():
		var p: Pawn = _sim.world.get_pawn(occ)
		if p != null:
			p.in_vehicle = 0; p.seat = -1
			if p.alive:
				p.is_downed = false  # vehicle destruction kills downed occupants too (blast is instant-kill)
				_apply_pawn_damage(occ, p, 99999, false, Revive.Source.BLAST, killer_id, 0)
	v.mark_destroyed(_sim.tick)
	var bytes := Protocol.encode_vehicle_destroyed(vid)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

func _step_vehicle_respawns() -> void:
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if v.alive: continue
		if v.respawn_tick > 0 and _sim.tick >= v.respawn_tick:
			v.respawn()

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
			for vid in _sim.world.vehicles:
				var vv: Vehicle = _sim.world.vehicles[vid]
				if vv.alive and vv.team != int(r["team"]) and nxt.distance_to(vv.pos) <= float(rdef["pawn_radius"]):
					_rkt_vs_veh += 1
			_blast_at(nxt, int(r["owner"]), int(r["team"]),
				int(rdef["pawn_damage"]), float(rdef["pawn_radius"]),
				int(rdef["struct_damage"]), float(rdef["struct_radius"]), RPG_VEHICLE_DMG)
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
## current positions, FF-off incl. thrower). Removes/chunk-mask deltas route through _damage_structure.
## (Smoke is handled by a branch added in Task 9.)
func _detonate(g: Dictionary) -> void:
	if int(g["type"]) == Grenade.SMOKE:
		_deploy_smoke(g)
		return
	if int(g["type"]) == Grenade.FLASHBANG:
		_detonate_flash(g)
		_broadcast_detonation(g["pos"], Protocol.DET_FLASH)
		return
	_nades += 1
	_blast_at(g["pos"], int(g["owner"]), int(g["team"]), GRENADE_DAMAGE_PAWN, BLAST_PAWN_RADIUS, GRENADE_DAMAGE_STRUCT, BLAST_STRUCT_RADIUS, FRAG_VEHICLE_DMG)
	_broadcast_detonation(g["pos"], Protocol.DET_EXPLOSION)

## Cosmetic explosion VFX (M7): tell every human client where a grenade detonated so it can spawn the
## blast/flash effect. Unreliable + bot clients skipped (they don't render). Unlike rocket_fx we do
## NOT skip the thrower — there is no client-predicted grenade arc, so the thrower needs this too.
func _broadcast_detonation(pos: Vector3, kind: int) -> void:
	var pkt := Protocol.encode_detonation(pos, kind)
	for cid in _clients:
		var c = _clients[cid]
		if bool(c.get("auto_deploy", true)):
			continue   # bot client — does not render
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, pkt, 0)

## Flashbang detonation (M5.5-P3): no damage. Blinds every LIVING pawn (any team — flashes are
## indiscriminate, BattleBit-style) within FLASH_RADIUS that has line-of-sight to the blast (a solid
## structure strictly between the blast and the eye blocks it). Blind is replicated as one byte for
## the M7 white-out (Task 6).
func _detonate_flash(g: Dictionary) -> void:
	_flashes += 1
	var center: Vector3 = g["pos"]
	for pid in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[pid]
		if not p.alive:
			continue
		var to: Vector3 = p.eye_position() - center
		var d := to.length()
		if d > FLASH_RADIUS or d < 0.001:
			continue
		if _store != null and _store.count() > 0 and bool(_store.march(center, to / d, d)["hit"]):
			continue   # LOS blocked by a structure
		p.blind_until_tick = maxi(p.blind_until_tick, _sim.tick + FLASH_BLIND_TICKS)
		_flash_blinds += 1

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

## Apply chunk damage to a piece from `source` at world `impact` (radius `radius`) and record the
## side effects for end-of-tick replication (_emit_structure_deltas). Destruction queues a remove +
## frees the cell (in damage_chunks); a non-lethal hole marks the piece for a chunk-mask resend.
func _damage_structure(id: int, source: int, impact: Vector3, radius: float) -> void:
	var cell := _cell_of_struct(id)       # capture BEFORE possible removal
	var pre := _store.get_record(id)
	var bid := int(pre.get("building_id", 0)) if not pre.is_empty() else 0
	var structural := (not pre.is_empty()) and _catalog.is_structural(int(pre["type"]))
	var res := _store.damage_chunks(id, source, impact, radius)
	if not res["hit"]:
		return
	_dmg += 1
	if res["destroyed"]:
		_destroyed += 1
		_pending_removes.append({"id": id, "cell": cell})
		_dmg_touched.erase(id)
		_remove_c4_on_cell(cell)
		if bid != 0 and structural:
			_buildings_to_cascade[bid] = true
	else:
		_dmg_touched[id] = true

## After this tick's structural removals, orphan-check each touched building. Large orphan sets
## collapse the whole building (one COLLAPSE broadcast); small sets queue per-piece removes.
func _resolve_cascades() -> void:
	if _buildings_to_cascade.is_empty():
		return
	for bid in _buildings_to_cascade.keys():
		var orphans := Support.orphaned_after(_store, bid, [])
		if orphans.is_empty():
			continue
		if Support.should_collapse(orphans.size()):
			for oid in _store.ids_of_building(bid):
				var crec := _store.get_record(oid)
				if not crec.is_empty():
					_remove_c4_on_cell(crec["cell"])
				_dmg_touched.erase(oid)
				_store.remove(oid)
			_collapsed += 1
			var bytes := Protocol.encode_collapse(bid)
			for cid in _clients:
				_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
		else:
			for oid in orphans:
				var orec := _store.get_record(oid)
				if orec.is_empty():
					continue
				var ocell: Vector3i = orec["cell"]
				_remove_c4_on_cell(ocell)
				_store.remove(oid)
				_pending_removes.append({"id": oid, "cell": ocell})
				_dmg_touched.erase(oid)
	_buildings_to_cascade.clear()

## Flush queued removes + chunk-mask deltas to interested clients, bounded by
## MAX_STRUCTURE_DELTAS_PER_TICK (removes first; overflow carried to next tick). Authoritative
## state is already applied — only the SEND volume is throttled. See docs/specs/destructible-buildings.md.
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
		_emit_structure_delta(Protocol.OP_CHUNK, {"id": id, "mask": int(rec["chunks"])}, rec["cell"])
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
	if _store.count() == 0 and _sites.count() == 0:
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
			for s in _sites.records_in_region(region):
				recs.append(_site_wire_record(s))
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
		_prev_climb_vault.erase(id)
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
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d struct=%d bld=%d rmv=%d blk=%d pen=%d dmg=%d destroyed=%d collapsed=%d nades=%d splash=%d smoke=%d rockets=%d rstruct=%d proj=%d projhit=%d projlive=%d projdrop=%d downed=%d bleedouts=%d revives=%d c4=%d mines=%d heals=%d ammo=%d bags=%d bagx=%d climbs=%d vaults=%d dropblk=%d enters=%d exits=%d veh_dead=%d repairs=%d repair_oh=%d rkt_veh=%d transport_m=%.1f ac_viol=%d swaps=%d supp=%d melees=%d backstabs=%d sledge=%d flashes=%d flashblinds=%d impacts=%d built_small=%d built_large=%d bsolo=%d dismantled=%d repaired=%d fobs_built=%d fob_spawns=%d fob_disabled=%d fobs_destroyed=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped, _conquest.tickets_int(0), _conquest.tickets_int(1), pts, _cap_events, _store.count(), _builds, _removes, _shots_blocked, _pen, _dmg, _destroyed, _collapsed, _nades, _splash_kills, _smokes, _rockets_det, _rstruct, _proj_fired, _proj_hits, _proj_live_max, _proj_dropped, _downed, _bleedouts, _revives, _c4_det, _mine_trips, _heals, _ammo_gives, _bags_thrown, _bags_exhausted, _climbs, _vaults, _drop_shoot_blocked, _enters, _exits, _veh_destroyed, _repairs, _repair_overheats, _rkt_vs_veh, _transport_max, _ac_viol, _swaps, _suppress_events, _melees, _backstabs, _sledge_hits, _flashes, _flash_blinds, _impacts, _built_small, _built_large, _build_blocked_solo, _dismantled, _repaired, _fobs_built, _fob_spawns, _fob_disabled, _fobs_destroyed])
	var pt := maxi(_phase_ticks, 1)
	print("[perf] us/tick: poll=%d move=%d veh=%d lag=%d interest=%d fire=%d respawn=%d conquest=%d match=%d snap=%d (ticks=%d)"
		% [_phase_us["poll"] / pt, _phase_us["move"] / pt, _phase_us["veh"] / pt, _phase_us["lag"] / pt, _phase_us["interest"] / pt, _phase_us["fire"] / pt, _phase_us["respawn"] / pt, _phase_us["conquest"] / pt, _phase_us["match"] / pt, _phase_us["snap"] / pt, _phase_ticks])
	for k in _phase_us: _phase_us[k] = 0
	_phase_ticks = 0
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0; _cap_events = 0
	_builds = 0; _removes = 0; _shots_blocked = 0; _pen = 0
	_dmg = 0; _destroyed = 0; _collapsed = 0; _nades = 0; _splash_kills = 0; _smokes = 0; _rockets_det = 0; _rstruct = 0; _proj_fired = 0; _proj_hits = 0; _proj_live_max = 0; _proj_dropped = 0; _dbg_last_min_y = INF; _downed = 0; _bleedouts = 0; _revives = 0; _c4_det = 0; _mine_trips = 0; _heals = 0; _ammo_gives = 0; _bags_thrown = 0; _bags_exhausted = 0; _climbs = 0; _vaults = 0; _drop_shoot_blocked = 0
	_enters = 0; _exits = 0; _veh_destroyed = 0; _repairs = 0; _repair_overheats = 0; _rkt_vs_veh = 0; _transport_max = 0.0
	_ac_viol = 0
	_swaps = 0
	_suppress_events = 0
	_melees = 0; _backstabs = 0; _sledge_hits = 0; _flashes = 0; _flash_blinds = 0; _impacts = 0
	_built_small = 0; _built_large = 0; _build_blocked_solo = 0; _dismantled = 0; _repaired = 0
	_fobs_built = 0; _fob_spawns = 0; _fob_disabled = 0; _fobs_destroyed = 0
