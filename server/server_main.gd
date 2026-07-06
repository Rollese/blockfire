extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), Conquest mode (capture points, tickets, win), squads, deploy/respawn.
## See docs/specs/m3-conquest-squads.md.

const Protocol := preload("res://shared/net/protocol.gd")
const ServerStats := preload("res://server/stats.gd")   # preload: class_name needs an --import to register
const ServerFire := preload("res://server/fire.gd")
const ServerSupport := preload("res://server/support.gd")
const ServerBuild := preload("res://server/build.gd")
const ReliableList := preload("res://server/reliable_list.gd")

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
# M8-P3 adaptive graceful degradation: these two snapshot levers become dynamic, driven by the
# Degrade ladder off windowed tick_mean. Level 0 == the consts above (no change under budget); when
# tick_mean breaches the high-water mark the server sheds snapshot rate + distant enemies to recover.
var _degrade_level := 0
var _snapshot_stride := SNAPSHOT_STRIDE
var _max_enemy_snapshot := MAX_ENEMY_SNAPSHOT
var _degrade_high_ms := Degrade.HIGH_MS   # --degrade-high-ms override (lower it to force-trigger in a test)
var _degrade_low_ms := Degrade.LOW_MS     # --degrade-low-ms override
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const COMBAT_FLAG_TICKS := 300     # 10s @30Hz — a pawn that took fire can't be a squad-spawn anchor (BattleBit "in combat")
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray
const FIRE_CONE_SKIP_RANGE := 8.0  # below this, skip the cone cull — feet/chest parallax exceeds the half-angle at point blank
const RPG_RELOAD_SECS := 3.0       # reload refills the rocket pool (RPG has no hit-scan mag)
const FIRE_RANGE_MARGIN := 20.0    # grid broad-phase slack for lag-comp movement
const MAP_PATH := "res://maps/conquest_proving_grounds.json"   # default; override with --map=<name>
const MATCH_STATE_INTERVAL := 15   # ticks between match-state broadcasts (2 Hz)
const KILL_SCORE := 100             # score points awarded to killer per kill
const ROSTER_STRIDE_TICKS := 30    # broadcast roster every N ticks (~1 Hz @30Hz)
const MATCH_END_DRAIN_TICKS := 300  # keep running ~10s after a win so clients can show the victory/defeat screen, then exit/rotate
const MAX_STRUCTURE_DELTAS_PER_TICK := 64   # graceful degradation: cap delta SENDS/tick
# Per-client per-tick cap on structure-baseline pieces. A fresh join / big move on a dense map (town =
# 8324 pieces) otherwise floods one tick with the whole map's baselines (reliable) — measured p99 spike
# to ~170ms at 48 bots. Structures are static, so streaming nearest-first over a few ticks (~0.5s on
# the densest map) is imperceptible and keeps the per-tick snapshot cost bounded. See BaselinePacer.
const MAX_STRUCTURE_BASELINE_PIECES_PER_TICK := 256
const BULLET_CARVE_RADIUS := 0.30   # m: chunks a single blocked bullet clears (M11)
const GRENADE_FUSE_TICKS := 45        # 1.5s @30Hz
const GRENADE_COOLDOWN_TICKS := 300   # 10s between a player's throws (shared frag/smoke)
const BLAST_PAWN_RADIUS := 8.0        # m, sphere (current positions, FF-off) — was 6, felt too small
const BLAST_STRUCT_RADIUS := 4.0      # m (~2 build cells)
const GRENADE_DAMAGE_PAWN := 100      # frag pawn splash at centre, linear falloff
const GRENADE_DAMAGE_STRUCT := 200    # frag structure blast GATE (>0 = enabled; magnitude unused — carve is governed by struct_radius, M11)
const IMPACT_CONTACT_RADIUS := 1.0    # m — an impact grenade detonates this close to an enemy pawn
const MELEE_DAMAGE := 75              # knife body hit; 2 front hits down EVERY armor tier (75*0.7=53 HEAVY -> 106), rear-arc back-stab instant-kills
const MELEE_COOLDOWN_TICKS := 18      # ~0.6s @30Hz between melee swings (was 24 — 0.8s felt like spam for a 2-hit front kill)
const SLEDGE_PAWN_DAMAGE := 35        # Engineer sledgehammer pawn-bonk (no structure in reach)
const SLEDGE_STRUCT_RADIUS := 1.5     # m — carve radius of one sledge swing on a structure cell
const FLASH_RADIUS := 8.0             # m — flashbang blinds exposed pawns within this radius (any team)
const FLASH_BLIND_TICKS := 90         # 3s @30Hz of white-out at the centre
const SMOKE_DURATION_TICKS := 390     # 13s @30Hz — smoke zone lifetime (long enough to cross an objective)
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
var _max_players := MAX_PLAYERS    # config-file max_players (M8-P3); no CLI flag
var _maps: Array = []        # rotation list (map basenames); empty = single-match default map
var _map_index := 0
var _rotate := false         # persistent multi-match loop active (config maps, no --map override)
var _boot_failed := false    # configure() ran pre-add_child (get_tree()==null there); _ready() exits on it
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
var _phase_us := {"poll": 0, "move": 0, "veh": 0, "lag": 0, "interest": 0, "fire": 0, "ordnance": 0, "support": 0, "build": 0, "respawn": 0, "conquest": 0, "match": 0, "snap": 0}
var _phase_ticks := 0
var _team_counts := {0: 0, 1: 0}
# Client ids with auto_deploy=false (rendered humans). Maintained on hello/disconnect so the
# eleven cosmetic/list broadcasters fan out O(humans) instead of scanning all 128 clients
# per event to skip bots.
var _human_ids: Array = []
var _positions := {}               # id -> Vector3, rebuilt each tick before fires
var _prev_climb_vault: Dictionary = {}   # id -> int bitmask: bit0=climbing, bit1=vaulting (edge counting)

var _stats := ServerStats.new()   # the [telemetry] counter wall — see server/stats.gd
var _fire := ServerFire.new(self)  # bullet pipeline + live projectile pool — see server/fire.gd
var _support := ServerSupport.new(self)  # revive/give/repair/downed latches + steps — see server/support.gd
var _build := ServerBuild.new(self)      # build sites + FOB lifecycle — see server/build.gd

var _roster_tick := 0
var _gadget_rl := ReliableList.new()   # GADGET_LIST changed+heartbeat state (server/reliable_list.gd)
# M12-P3: squad-leader FOB registry. "team:squad" -> {squad, team, id, cell, built: bool}
var _transport_origin := {}   # id -> Vector3 boarding pos (transport-distance metric)
var _pending_removes: Array = []   # [{id, cell}] removes awaiting send (degradation queue)
var _dmg_touched := {}             # id -> true: pieces holed (alive) this tick, for end-of-tick chunk-mask resend
var _buildings_to_cascade := {}    # building_id -> true; resolved at end of tick
var _collapsed_bids: Array = []    # building_ids fully collapsed this match — replayed to late joiners
                                   # (A3 playtest bug: a reconnecting client rebuilt every map ladder
                                   # from the static MapDef and showed ghost ladders on dead buildings)
var _collapse_test_bid := 0        # QA (--collapse-test=<bid>): force-collapse that building ~5s in.
var _fast_nades := false           # QA (--fast-nades): drop the grenade throw cooldown to ~1 tick so a playtester can level a building fast (destruction/ladder testing).
var _fast_rpg := false             # QA (--fast-rpg): RPG fires with no cooldown and never depletes rockets (pairs with --human-rpg for fast destruction testing).
                                   # Whole-building collapse is rare in bot-only runs, so this is the
                                   # on-demand exerciser for the collapse/ladder/rubble/join-replay path.
var _grenades: Array = []     # [{owner, team, type, pos, vel, detonate_tick}] — server-side, not replicated
var _rockets: Array = []      # [{owner, team, pos, vel}] — server-side, not replicated
var _mines: Array = []        # [{owner, team, pos, facing, armed_after_tick}]
var _support_rl := ReliableList.new()  # SUPPORT_LIST
var _downed_rl := ReliableList.new()   # DOWNED_LIST
var _fob_rl := ReliableList.new()      # FOB_LIST ({team: pkt} payload)
var _bags: Array = []          # [{owner, team, kind, pos, pool}]
var _c4: Dictionary = {}      # owner_id -> Array of {pos, cell:Vector3i}
var _smoke_zones: Array = []  # [{pos, radius, expire_tick}] — server-side; M7 LOS culling consumes
var _prev_owners: Array = []
var _match_over_broadcast := false
var _match_end_tick := -1

var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	var loaded := ServerConfig.load_file(String(args.get("config", ServerConfig.DEFAULT_PATH)))
	if not loaded["ok"]:
		# An operator-authored config that doesn't parse must fail loud, not silently
		# fall back to defaults mid-LAN-party. get_tree() is null here (configure runs
		# pre-add_child) — flag it and _ready() exits.
		push_error("[server] %s" % loaded["error"])
		_boot_failed = true
		return
	var eff := ServerConfig.resolve(loaded["config"], args)
	_port = eff["port"]
	_max_players = eff["max_players"]
	_start_tickets = eff["tickets"]
	_time_limit = eff["time_limit"]
	_maps = eff["maps"]
	_rotate = eff["rotate"]
	if not _maps.is_empty():
		_map_path = "res://maps/%s.json" % String(_maps[0])
	_human_rpg = args.has("human-rpg")
	_collapse_test_bid = int(args["collapse-test"]) if args.has("collapse-test") else 0
	_fast_nades = args.has("fast-nades")
	_fast_rpg = args.has("fast-rpg")
	if eff["degrade_high_ms"] > 0.0:
		_degrade_high_ms = eff["degrade_high_ms"]
	if eff["degrade_low_ms"] > 0.0:
		_degrade_low_ms = eff["degrade_low_ms"]
	if _degrade_low_ms >= _degrade_high_ms:
		# An inverted band makes Degrade.next_level climb one window and descend the next,
		# thrashing the snapshot stride every second. Operator error -> safe defaults.
		push_warning("[server] degrade band low (%.1f) must be < high (%.1f); using defaults %0.1f/%0.1f"
			% [_degrade_low_ms, _degrade_high_ms, Degrade.LOW_MS, Degrade.HIGH_MS])
		_degrade_high_ms = Degrade.HIGH_MS
		_degrade_low_ms = Degrade.LOW_MS
	if _rotate:
		print("[server] map rotation active: %s" % ", ".join(PackedStringArray(_maps)))

func _ready() -> void:
	if _boot_failed:
		get_tree().quit(1); return
	_catalog = PieceCatalog.load_file(PIECES_PATH)
	if _catalog == null:
		push_error("[server] failed to load pieces %s" % PIECES_PATH); get_tree().quit(1); return
	_gadgets = Gadget.load_file(GADGETS_PATH)
	if _gadgets == null:
		push_error("[server] failed to load gadgets %s" % GADGETS_PATH); get_tree().quit(1); return
	_attachments = Attachment.load_file(ATTACHMENTS_PATH)
	if _attachments == null:
		push_error("[server] failed to load attachments %s" % ATTACHMENTS_PATH); get_tree().quit(1); return
	_vehicles_cat = VehicleCatalog.load_file(VEHICLES_PATH)
	if _vehicles_cat == null:
		push_error("[server] failed to load vehicles %s" % VEHICLES_PATH); get_tree().quit(1); return
	if not _start_match():
		get_tree().quit(1); return
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, _max_players)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d map=%s" % [_port, TICK_RATE, _max_players, _map.name])
	# NOTE (M8-P3): graceful SIGTERM/SIGINT shutdown is NOT implemented — verified that headless
	# Godot 4.6 does not deliver POSIX signals as NOTIFICATION_WM_CLOSE_REQUEST (no display server),
	# and GDScript has no signal-handler API, so the process takes the OS default (exit 143/130).
	# A clean teardown needs either a native GDExtension signal handler or an admin control-channel
	# SHUTDOWN command; deferred. For a LAN dedicated server this is benign — a terminated match just
	# ends (no persistence), peers ENet-timeout, and `docker stop` SIGKILLs after its grace period.

## Load the map and build all match-scoped state. Called at boot and again at each
## map-rotation boundary (M8-P3). Returns false when the map fails to load.
func _start_match() -> bool:
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[server] failed to load map %s" % _map_path); return false
	_conquest = ConquestState.new(_map)
	if _start_tickets > 0:
		_conquest.tickets = [float(_start_tickets), float(_start_tickets)]
	if _time_limit > 0.0:
		_conquest.time_limit = _time_limit
	_prev_owners = _owner_snapshot()
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
	var _b_gen_idx := -1
	for b in _map.buildings:
		_b_gen_idx += 1   # generation index (matches the map_gen ladder "building" field); ++ even on skip
		var pres := BuildingCatalog.load_file("res://buildings/%s.json" % b["prefab"], _catalog)
		if not pres["ok"]:
			push_error("[map] building '%s': %s" % [b["prefab"], pres["error"]]); continue
		var bid := _next_building_id
		_next_building_id += 1
		# H1: stamp this building's authoritative id onto its roof ladder(s) (matched by generation
		# index) so a full collapse can drop the climb volume. Robust to prefab-load skips above.
		for ld in _sim.ladders:
			if int(ld.get("building_index", -1)) == _b_gen_idx:
				ld["building_id"] = bid
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
	_spawn_map_vehicles()
	return true

## Match boundary in rotation mode: disconnect everyone, wipe every piece of
## match-scoped state, load the next map, keep listening. Boot-scoped state
## (net host, catalogs, config, rolling telemetry) survives.
func _rotate_match() -> void:
	_map_index = ServerConfig.next_map_index(_map_index, _maps.size())
	_map_path = "res://maps/%s.json" % String(_maps[_map_index])
	print("[server] match complete — rotating to %s" % String(_maps[_map_index]))
	if _net != null:
		_net.disconnect_all()
	_reset_match_state()
	if not _start_match():
		# A rotation entry pointing at a missing/broken map is an operator config error;
		# a dead persistent server is worse than a loud exit.
		push_error("[server] rotation failed to load %s — exiting" % _map_path)
		get_tree().quit(1)

## Wipe all match-scoped state. Complements _start_match(), which rebuilds
## map/conquest/store/vehicles. Keep this list in sync with the var block at the
## top of the file: every match-scoped var either resets HERE or is rebuilt in
## _start_match(). (Modules holding a `srv` back-ref dereference _sim/_store
## lazily, so re-instantiating them BEFORE _start_match rebuilds _store is safe.)
func _reset_match_state() -> void:
	_sim = SimLoop.new()
	_grid.clear()
	_lag.clear()
	_squads = SquadManager.new()
	_stats = ServerStats.new()
	_fire = ServerFire.new(self)
	_support = ServerSupport.new(self)
	_build = ServerBuild.new(self)
	_gadget_rl = ReliableList.new()
	_support_rl = ReliableList.new()
	_downed_rl = ReliableList.new()
	_fob_rl = ReliableList.new()
	_clients.clear()
	_peer_to_id.clear()
	_human_ids.clear()
	_team_counts = {0: 0, 1: 0}
	_positions.clear()
	_prev_climb_vault.clear()
	_transport_origin.clear()
	_pending_removes.clear()
	_dmg_touched.clear()
	_buildings_to_cascade.clear()
	_collapsed_bids.clear()   # map rotation rebuilds every building — don't replay stale collapses
	_grenades.clear()
	_rockets.clear()
	_mines.clear()
	_bags.clear()
	_c4.clear()
	_smoke_zones.clear()
	_prev_owners = []
	_match_over_broadcast = false
	_match_end_tick = -1
	_roster_tick = 0
	_next_struct_id = 1
	_next_id = 1
	_degrade_level = 0
	_snapshot_stride = SNAPSHOT_STRIDE
	_max_enemy_snapshot = MAX_ENEMY_SNAPSHOT
	_tele_accum = 0.0            # per-second telemetry window restarts with the match
	_impact_fx_this_tick = 0     # cosmetic impact-FX budget counter
	_phase_ticks = 0
	for k in _phase_us:
		_phase_us[k] = 0

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	var t_poll := Time.get_ticks_usec()
	# QA: --collapse-test=<bid> exercises the full collapse path (piece drop, ladder removal,
	# COLLAPSE broadcast + late-join replay) on demand, ~5s in so early clients see it live.
	if _collapse_test_bid > 0 and _sim.tick == 150:
		print("[server] QA collapse-test: collapsing building %d" % _collapse_test_bid)
		_collapse_building(_collapse_test_bid)
		_collapse_test_bid = 0
	_step_movement()
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		var cur: int = (1 if p.climbing else 0) | (2 if p.vaulting else 0)
		var prv: int = _prev_climb_vault.get(id, 0)
		if (cur & 1) != 0 and (prv & 1) == 0:
			_stats.climbs += 1
		if (cur & 2) != 0 and (prv & 2) == 0:
			_stats.vaults += 1
			_broadcast_vault_fx(id)   # cosmetic: a vault just started -> remote mantle pose
		_prev_climb_vault[id] = cur
	var t_move := Time.get_ticks_usec()
	_sim.step_vehicles(_build_vehicle_inputs(), _map.world_half)
	_track_transport_distance()
	var t_veh := Time.get_ticks_usec()
	# Rewind consumers: the mounted gun, and infantry bullets fired by a HUMAN (their view lags
	# ~100 ms behind the sim, so hits on movers must rewind the target to the shooter's view tick —
	# fire.gd). Recording ~129 dicts/tick is wasted when only bots are shooting (bots aim at present,
	# view_tick=0 -> no rewind), so an all-bot fleet gate records nothing. Cleared on pause so a
	# later remount/join can't rewind into stale frames.
	if _mounted_gunner_exists() or not _human_ids.is_empty():
		_lag.record(_sim.tick, _sim.world)
	elif _lag.has_history():
		_lag.clear()
	var t_lag := Time.get_ticks_usec()
	_build_interest()
	var t_int := Time.get_ticks_usec()
	_fire.resolve_fires()
	_fire.resolve_vehicle_fires()
	_fire.step_projectiles()   # bullets spawned by _resolve_fires step in present time (M5.5-P1)
	# M5.5-P2: decay suppression once per tick, after accrual in _step_projectiles (accrue-then-decay).
	for sid in _sim.world.pawns:
		var sp: Pawn = _sim.world.pawns[sid]
		if sp.suppression > 0.0:
			sp.suppression = Suppress.decay(sp.suppression)
	var t_fire := Time.get_ticks_usec()
	_step_grenades()
	_step_rockets()
	_step_mines()
	var t_ord := Time.get_ticks_usec()
	_support.links_this_tick.clear()   # rebuilt by the give/repair/revive steps below for SUPPORT_LIST
	_support.step_active_give()
	_support.step_repairs()
	_step_bags()
	_expire_smoke_zones()
	_support.step_revives()
	_support.step_downed()
	var t_supp := Time.get_ticks_usec()
	# Build sites moved below the support steps for profiler-bucket contiguity — safe: none of
	# give/repairs/bags/smoke/revives/downed read the structure store, and cascades/deltas run later.
	_build.step_build_sites()   # M12-P2: cooperative shovel construction / repair / dismantle
	var t_build := Time.get_ticks_usec()
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
	_broadcast_downed_list()
	_send_fob_lists()
	var t_snap := Time.get_ticks_usec()
	_phase_us["poll"] += t_poll - t0
	_phase_us["move"] += t_move - t_poll
	_phase_us["veh"] += t_veh - t_move
	_phase_us["lag"] += t_lag - t_veh
	_phase_us["interest"] += t_int - t_lag
	_phase_us["fire"] += t_fire - t_int
	_phase_us["ordnance"] += t_ord - t_fire
	_phase_us["support"] += t_supp - t_ord
	_phase_us["build"] += t_build - t_supp
	_phase_us["respawn"] += t_resp - t_build
	_phase_us["conquest"] += t_conq - t_resp
	_phase_us["match"] += t_match - t_conq
	_phase_us["snap"] += t_snap - t_match
	_phase_ticks += 1
	_tele.record_tick_ms(float(t_snap - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0
	if _match_over_broadcast and _sim.tick >= _match_end_tick + MATCH_END_DRAIN_TICKS:
		if _rotate:
			_rotate_match()
		else:
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
		# Tick-lead: depth right after this tick's drain — what the owner client's clock loop tracks.
		c["input_buf_depth"] = c["input_buf"].size()
		if inp != null:
			inputs[id] = inp
			var prev_inp = c["last_input"]
			if prev_inp != null and inp != prev_inp:
				if not InputValidate.view_rate_ok(float(prev_inp["yaw"]), float(inp["yaw"]), float(prev_inp["pitch"]), float(inp["pitch"]), MAX_VIEW_RATE):
					_stats.ac_viol += 1
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
## True while any live mounted-gun vehicle has its gunner seat occupied — gates lag-comp
## recording (see the tick loop). Vehicle counts are tiny (~4), so this scan is cheap.
func _mounted_gunner_exists() -> bool:
	for vid in _sim.world.vehicles:
		var v: Vehicle = _sim.world.vehicles[vid]
		if not v.alive or v.mounted.is_empty():
			continue
		for seat in v.seats.size():
			if int(v.seat_roles[seat]) == Vehicle.ROLE_GUNNER and int(v.seats[seat]) != 0:
				return true
	return false

## Send `pkt` to every HUMAN client (auto_deploy=false), optionally excluding one id (the
## actor, who renders its own effect locally). Bots don't render — the cached _human_ids
## list keeps every cosmetic/list fan-out O(humans) instead of an O(128) skip-scan per event.
func _broadcast_humans(channel: int, pkt: PackedByteArray, flags: int = 0, exclude: int = 0) -> void:
	for cid in _human_ids:
		if cid == exclude:
			continue
		_net.send_to(_clients[cid]["peer"], channel, pkt, flags)

## M7.5-P3 sibling of _broadcast_humans: send `pkt` to EVERY client — bots included —
## optionally excluding one id. Only for the fair-play broadcasts bots also consume
## (GADGET_LIST, GRENADE_FX); the purely-cosmetic *_FX/list fan-outs stay human-only.
## Perf: encode ONCE (caller), send N — this loop is send-only, so 128 clients cost
## 128 enet sends of one shared small packet. The 128-bot fleet gate is the budget proof.
func _broadcast_all(channel: int, pkt: PackedByteArray, flags: int = 0, exclude: int = 0) -> void:
	for cid in _clients:
		if cid == exclude:
			continue
		_net.send_to(_clients[cid]["peer"], channel, pkt, flags)

func _broadcast_shot_fx(shooter_id: int, origin: Vector3, dir: Vector3) -> void:
	# Cosmetic remote-tracer hint. Unreliable (droppable); shooter excluded (renders its own).
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_shot_fx(origin, dir, shooter_id), 0, shooter_id)

func _broadcast_vault_fx(vault_id: int) -> void:
	# Cosmetic remote-vault cue. Unreliable (droppable); vaulter excluded.
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_vault_fx(vault_id), 0, vault_id)

func _broadcast_melee_fx(melee_id: int) -> void:
	# Cosmetic remote-melee cue. Unreliable; swinger excluded (sees its own viewmodel swing).
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_melee_fx(melee_id), 0, melee_id)

func _broadcast_reload_fx(reloader_id: int, duration_ticks: int) -> void:
	# Cosmetic remote-reload cue. Unreliable; reloader excluded (viewmodel + SELF_STATE cover it).
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_reload_fx(reloader_id, duration_ticks), 0, reloader_id)

const MAX_IMPACT_FX_PER_TICK := 24   # bound the cosmetic-impact fan-out per tick at bot scale
var _impact_fx_this_tick := 0

## Cosmetic bullet-impact puff at world geometry. Sent to ALL human clients (the shooter wants to
## see their own rounds chip the wall too). Unreliable + per-tick capped.
func _broadcast_impact_fx(pos: Vector3, kind: int) -> void:
	if _impact_fx_this_tick >= MAX_IMPACT_FX_PER_TICK:
		return
	_impact_fx_this_tick += 1
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_impact_fx(pos, kind))


func _down_pawn(victim: Pawn) -> void:
	victim.is_downed = true
	victim.down_count += 1   # halving bleedout: each down this life shrinks the window
	victim.bleed_health = 0
	victim.bleed_floor = Revive.bleedout_floor(Revive.bleedout_window(victim.down_count))
	victim.bleed_halted = false
	_stats.downed += 1
	# No ticket cost and no KILL event at down — only true death spends a ticket.

func _kill_pawn(vid: int, victim: Pawn, killer_id: int, weapon_id: int, headshot: bool, source: int) -> void:
	var was_downed := victim.is_downed   # true => bleed-out/give-up; recap uses the down-time snapshot
	victim.alive = false
	victim.is_downed = false
	# Vacate any vehicle seat on death, else the per-tick seat-follow drags the pawn back to
	# the seat after it respawns elsewhere (HQ/teammate) — trapping the player in the vehicle.
	_vacate_seat(victim)
	if _clients.has(vid):   # pawn can outlive its client (disconnect race) — same guard as below
		if _clients[vid].get("auto_deploy", true):
			_clients[vid]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
		else:
			# auto_deploy=false (human): returns to deploy screen, but not before a respawn cooldown
			# (death has weight; the body stays put until they can redeploy).
			_clients[vid]["deploy_ready_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
	_conquest.register_death(victim.team)
	_stats.kills += 1
	if _clients.has(vid):
		_clients[vid]["deaths"] = int(_clients[vid]["deaths"]) + 1
	if _clients.has(killer_id) and killer_id != vid:
		_clients[killer_id]["kills"] = int(_clients[killer_id]["kills"]) + 1
		_clients[killer_id]["score"] = int(_clients[killer_id]["score"]) + KILL_SCORE
	if source == Revive.Source.BLAST:
		_stats.splash_kills += 1
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
	var pre_hp := maxi(int(victim.health), 0)   # health before this hit — caps the recap ledger credit
	victim.health -= dmg
	victim.combat_until_tick = _sim.tick + COMBAT_FLAG_TICKS   # taking fire flags "in combat" (blocks squad-spawn on this pawn)
	if _clients.has(vid):
		var src: Pawn = _sim.world.get_pawn(killer_id)
		var bearing: float = DamageDir.bearing(victim.pos, src.pos) if src != null else 0.0
		_net.send_to(_clients[vid]["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_damage_event(bearing, dmg), 0)
		if killer_id != 0:
			# Credit only the damage actually dealt (min of raw dmg and the victim's pre-hit health).
			# Instant-kill sentinels (back-stab 100000 / vehicle-crush 99999) would otherwise clamp to
			# u16-max (65535) on the DEATH_INFO wire and show a nonsense "65535 damage" on the recap.
			var led: Dictionary = _clients[vid]["dmg_ledger"]
			led[killer_id] = int(led.get(killer_id, 0)) + mini(dmg, pre_hp)
	if victim.health > 0:
		return
	victim.health = 0
	# Instant kill on headshot/blast, OR when this life's next down would have a zero-length window
	# (halving bleedout exhausted — a heavily re-downed pawn dies outright instead of entering DBNO).
	if Revive.is_instant_kill(headshot, source) or Revive.bleedout_window(victim.down_count + 1) <= 0:
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
			p.down_count = 0     # fresh life: re-arm the full 60 s bleedout window
			p.bleed_floor = 0
			p.combat_until_tick = 0   # fresh spawn is not "in combat"
			p.climbing = false   # clear special-movement state so a pawn that died mid-climb/vault
			p.vaulting = false   # doesn't resume the arc/ladder at its fresh spawn (ghost-vault fix)
			p.bleed_halted = false
			p.bandage_count = Revive.bandage_count_for(_support.is_medic(id))
			p.grounded = true
			p.fall_peak_y = p.pos.y
			p.landed_fall = 0.0
			p.suppression = 0.0       # fresh life: no residual spread penalty
			p.blind_until_tick = 0    # a flashbang taken last life doesn't white-out the respawn
			c["respawn_tick"] = 0
			_reset_weapon_loadout(c)   # both slots full, fire-mode defaults, back on primary
			_force_reenter(id)         # a swapper who died holding secondary respawns on primary
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
		# Spawn-on-squadmate is valid anywhere (BattleBit) EXCEPT: the anchor must be up (not downed)
		# and NOT in combat — a mate who has taken fire in the last COMBAT_FLAG_TICKS can't be spawned
		# on, which stops enemies camping your HQ by parking a squadmate there (they get shot -> flagged).
		if mp != null and mp.alive and not mp.is_downed and _sim.tick >= mp.combat_until_tick:
			mates.append(mp.pos)
	var fob_pos = _build.spawnable_fob_pos(team, int(c["squad"]))
	# fob_disabled is a spawn-DECISION counter: a built+alive FOB exists but was enemy-suppressed.
	# Tally it here (the spawn path), NOT inside _spawnable_fob_pos — that helper is also called every
	# tick per human client by _send_fob_lists/_fob_candidates, which would turn the metric into
	# disabled-render-frames. _fob_built_alive distinguishes "disabled" from "absent/destroyed".
	if fob_pos == null and _build.fob_built_alive(team, int(c["squad"])):
		_stats.fob_disabled += 1
	var fobs: Array = [fob_pos] if fob_pos != null else []
	var r := SpawnSelect.choose(team, _map, _conquest, mates, obj, fobs)
	if int(r["kind"]) == SpawnSelect.SRC_FOB:
		_stats.fob_spawns += 1
	return r["pos"]

## True if the squad has a completed, not-yet-destroyed FOB structure (regardless of enemy proximity).
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
			_stats.cap_events += 1
			_stats.cap_events_total += 1
	_prev_owners = owners
	if _conquest.match_over and not _match_over_broadcast:
		_match_over_broadcast = true
		_match_end_tick = _sim.tick
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], true, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
		print("[match] OVER winner=%d t0=%d t1=%d elapsed=%ds cap_events=%d"
			% [_conquest.winner, _conquest.tickets_int(0), _conquest.tickets_int(1), int(_conquest.elapsed), _stats.cap_events_total])
	elif not _match_over_broadcast and _sim.tick % MATCH_STATE_INTERVAL == 0:
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], false, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	# Stamp the live equipped weapon (kept in the client record, not the pawn) onto each entity so it
	# rides the snapshot ENTER record like armor_class — lets remotes render the right weapon
	# silhouette. Once per tick (state_map is shared across all clients' sends this tick).
	for sid in state:
		if _clients.has(sid):
			(state[sid] as EntityState).weapon = int(_clients[sid].get("weapon", Weapon.AR))
	var vstate := _sim.world.vehicle_state_map()
	for id in _clients:
		# Stagger sends across ticks so the per-tick snapshot encode cost (the dominant tick
		# cost at high player counts) is ~clients/SNAPSHOT_STRIDE rather than O(clients).
		if (_sim.tick + id) % _snapshot_stride != 0:
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
				if enemy_kept >= _max_enemy_snapshot:
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
		var rgauge := _support.repair_gauge_for(id)
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL,
			Protocol.encode_self_state(int(c["ammo"]), bool(c["reloading"]), reload_remaining, int(c["weapon"]), _throwables_for(c), _support.being_revived.has(id), self_pawn.suppression, clampi(self_pawn.blind_until_tick - _sim.tick, 0, 255), self_pawn.bandage_count, self_pawn.bleed_halted, rgauge.x, rgauge.y, self_pawn.stamina, self_pawn.velocity.y, self_pawn.grounded, self_pawn.vaulting, self_pawn.vault_tick, self_pawn._regen_cooldown, self_pawn._sprint_locked, int(c["input_buf_depth"])),
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
		Protocol.Msg.BUILD_REQUEST: _build.handle_build_request(peer, bytes)
		Protocol.Msg.PLACE_FOB: _build.handle_place_fob(peer, bytes)
		Protocol.Msg.REMOVE_FOB: _build.handle_remove_fob(peer)
		Protocol.Msg.BUILD_REMOVE: _build.handle_build_remove(peer, bytes)
		Protocol.Msg.GRENADE_THROW: _handle_grenade_throw(peer, bytes)
		Protocol.Msg.REVIVE_ACTION: _support.handle_revive_action(peer, bytes)
		Protocol.Msg.GIVE_UP: _support.handle_give_up(peer)
		Protocol.Msg.GADGET_ACTION: _handle_gadget_action(peer, bytes)
		Protocol.Msg.VEHICLE_ACTION: _handle_vehicle_action(peer, bytes)
		Protocol.Msg.DEPLOY_REQUEST: _handle_deploy_request(peer, bytes)
		Protocol.Msg.SET_SQUAD: _handle_set_squad(peer, bytes)
		Protocol.Msg.SET_FIRE_MODE: _handle_set_fire_mode(peer, bytes)
		Protocol.Msg.SWAP_WEAPON: _handle_swap_weapon(peer, bytes)
		Protocol.Msg.MELEE: _handle_melee(peer, bytes)
		_: pass

func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	# One HELLO per connection: a repeated HELLO on an already-welcomed peer would mint a fresh
	# id/pawn/team/squad slot every time (slot-exhaustion DoS; only the newest id would be cleaned
	# on disconnect). Re-send the WELCOME idempotently instead — covers a reliable-channel retry.
	var existing_id: int = _peer_to_id.get(peer, 0)
	if existing_id != 0 and _clients.has(existing_id):
		var ec = _clients[existing_id]
		_net.send_to(peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_welcome(existing_id, TICK_RATE, int(ec["class"]), _map_path.get_file().get_basename()),
			ENetPacketPeer.FLAG_RELIABLE)
		return
	var hello := Protocol.decode_hello(bytes)
	var ver := int(hello["ver"])
	var pname := String(hello["name"])
	var auto_deploy := bool(hello["auto_deploy"])
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	if _clients.size() >= _max_players:
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
		"input_buf_depth": 0,   # post-drain depth, sampled in _step_movement (tick-lead SELF_STATE byte)
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
	if not auto_deploy:
		_human_ids.append(id)   # rendered client: joins the cosmetic/list broadcast fan-out
	var p := _sim.world.spawn(id)
	p.team = team
	p.squad = squad
	p.auto_vault = bool(auto_deploy)   # bots (auto_deploy) vault on contact; humans press jump to vault (BattleBit)
	p.pos = _select_spawn(id)
	p.armor_class = Loadout.armor_for(cls)   # M5.5-P2: tier is class-derived, immutable per life
	p.bandage_count = Revive.bandage_count_for(cls == Loadout.MEDIC)
	if not auto_deploy:
		p.alive = false   # held un-deployed until DEPLOY_REQUEST (respawn_tick stays 0)
	# Tell the client which map to render (its roads/points/bases come from its local MapDef) so it
	# never has to be launched with a matching --map. Send the file basename, not the display name.
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE, cls, _map_path.get_file().get_basename()), ENetPacketPeer.FLAG_RELIABLE)
	# Replay this match's building collapses to the joiner (reliable, a few bytes each). The client
	# builds ladders/geometry from the static MapDef, so without this a late joiner renders ghost
	# roof ladders (and no rubble) where buildings already fell (A3, playtest 2026-07-05). The
	# client-side COLLAPSE path is idempotent, so joiners who lived through the event are unaffected.
	for cbid in _collapsed_bids:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_collapse(int(cbid)), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d squad=%d class=%d — %d peers" % [id, pname, team, squad, cls, _clients.size()])

func _squad_candidates(req_id: int, team: int, squad_id: int) -> Array:
	var out: Array = []
	for mid in _squads.members(team, squad_id):
		if mid == req_id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp == null: continue
		# Same anti-HQ-camp rule as the auto-respawn path (_select_spawn): a mate who took fire in
		# the last COMBAT_FLAG_TICKS is not a valid spawn anchor. Without this, only bots honoured it.
		if _sim.tick < mp.combat_until_tick: continue
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
func _grenade_cooldown_ticks(c: Dictionary) -> int:
	# --fast-nades: near-instant re-throw for destruction testing, HUMANS ONLY (auto_deploy=false) so
	# bots don't nade-spam the map into rubble during a playtest.
	return 1 if _fast_nades and not bool(c["auto_deploy"]) else GRENADE_COOLDOWN_TICKS

func _throwables_for(c: Dictionary) -> Array:
	var ready := 1 if _sim.tick - int(c["last_grenade_tick"]) >= _grenade_cooldown_ticks(c) else 0
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
	var fobs := _build.fob_candidates(int(c["team"]))
	if not DeploySpawn.is_valid(int(c["team"]), ref, _map, _conquest, mates, vehs, fobs): return
	var dpos := DeploySpawn.resolve(int(c["team"]), ref, _map, _conquest, mates, vehs, fobs)
	if ref >= DeploySpawn.FOB_BASE: _stats.fob_spawns += 1
	p.pos = dpos
	p.velocity = Vector3.ZERO
	p.health = 100
	p.alive = true
	p.stamina = Pawn.STAMINA_MAX
	p.is_downed = false
	# Fresh life: re-arm the halving-bleedout state exactly like _handle_respawns. Without this the
	# manual-deploy path carried down_count across lives, so a human who accrued a few downs earlier in
	# the match bled out almost instantly on the FIRST down of a new life (G1 playtest regression).
	p.down_count = 0
	p.bleed_floor = 0
	p.bleed_health = 0
	p.bleed_halted = false
	p.bandage_count = Revive.bandage_count_for(_support.is_medic(id))
	p.combat_until_tick = 0
	p.climbing = false
	p.vaulting = false
	p.in_vehicle = 0   # defensive: never deploy still bound to a seat
	p.seat = -1
	p.grounded = true
	p.fall_peak_y = p.pos.y
	p.landed_fall = 0.0
	p.suppression = 0.0       # fresh life: no residual spread penalty (same as _handle_respawns)
	p.blind_until_tick = 0    # a flashbang taken last life doesn't white-out the fresh deploy
	_reset_weapon_loadout(c)   # both slots full, fire-mode defaults, back on primary
	_force_reenter(id)         # weapon rides ENTER-only — refresh remote silhouettes after reset
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

## Drop pawn `pid` from every client's stored snapshot baselines so the next send emits a
## fresh ENTER record for it. ENTER is the only record that carries the equipped-weapon
## (and armor) byte, and decode_apply updates an existing view entry in place — so this is
## how a mid-life weapon change reaches remotes that never lost interest in the pawn.
## Cost: O(clients × MAX_HISTORY) dictionary erases; swaps are rare.
func _force_reenter(pid: int) -> void:
	for cid in _clients:
		var c: Dictionary = _clients[cid]
		if not c.has("history"):
			continue   # no snapshot sent yet -> no baselines to erase
		var hist: Dictionary = c["history"]
		for s in hist:
			(hist[s] as Dictionary).erase(pid)

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
	_force_reenter(id)                 # weapon rides ENTER-only — refresh remote silhouettes
	_stats.swaps += 1

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

func _handle_grenade_throw(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive or p.is_downed or p.climbing: return   # downed/climbing = incapacitated (same gate as fire/melee/gadgets)
	if _sim.tick - int(c["last_grenade_tick"]) < _grenade_cooldown_ticks(c): return
	var d := Protocol.decode_grenade_throw(bytes)
	var dir: Vector3 = d["dir"]
	if dir.length() < 0.001: return
	c["last_grenade_tick"] = _sim.tick
	var gtype := int(d["type"])
	if gtype < Grenade.FRAG or gtype > Grenade.IMPACT:
		gtype = Grenade.FRAG   # reject unknown throwable ids (default to frag)
	# Humans own only what SELF_STATE advertises (frag + smoke); FLASHBANG/IMPACT are bot-exerciser
	# throwables. Without this a modified client throws IMPACT — strictly better than frag (contact fuse).
	if not bool(c["auto_deploy"]) and gtype != Grenade.FRAG and gtype != Grenade.SMOKE:
		gtype = Grenade.FRAG
	var charge := float(d.get("charge", 1.0))   # hold-strength: longer hold -> faster/farther throw
	_grenades.append({
		"owner": id, "team": p.team, "type": gtype,
		"pos": p.eye_position(), "vel": Grenade.launch_velocity(dir, charge),
		"detonate_tick": _sim.tick + GRENADE_FUSE_TICKS,
	})
	# Cosmetic: let other human clients see the grenade arc through the air (FRAG/SMOKE only — IMPACT
	# isn't in a human loadout and detonates on contact). The thrower renders their own locally.
	if gtype == Grenade.FRAG or gtype == Grenade.SMOKE:
		_broadcast_grenade_fx(id, p.eye_position(), dir.normalized(), gtype, p.team, charge)

func _handle_melee(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	_resolve_melee(id, int(Protocol.decode_melee(bytes)["view_server_tick"]))

## Melee swing (M5.5-P3). Knife (all classes): the nearest enemy in the frontal reach cone takes
## MELEE_DAMAGE, or an instant kill if struck within the rear arc (back-stab). Cooldown-gated per
## client. (The Engineer sledgehammer structure branch is added in Task 4.)
func _resolve_melee(id: int, view_tick: int = 0) -> void:
	var c = _clients[id]
	if _sim.tick < int(c.get("melee_ready_tick", 0)): return
	c["melee_ready_tick"] = _sim.tick + MELEE_COOLDOWN_TICKS
	var atk: Pawn = _sim.world.get_pawn(id)
	if atk == null or not atk.alive or atk.is_downed or atk.climbing: return   # no melee while climbing
	# Lag-comp: rewind target positions to the attacker's rendered view tick (like fire.gd), so a swing
	# at a moving target lands where the player saw them instead of missing present-time. The attacker
	# stays present (well-predicted local pawn). view_tick 0 => present-time (old client / sledge march).
	var lag_frame: Dictionary = _lag.rewind(view_tick) if view_tick > 0 and _lag.has_history() else {}
	_broadcast_melee_fx(id)   # cosmetic: a real swing happened (cooldown passed, attacker valid)
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
				_stats.sledge_hits += 1
				return
	var enemies: Array = []
	for tid in _sim.world.pawns:
		var v: Pawn = _sim.world.pawns[tid]
		if v != null and v.alive and not v.is_downed and v.team != atk.team:
			var tpos: Vector3 = lag_frame[tid]["pos"] if lag_frame.has(tid) else v.pos
			enemies.append({"id": tid, "pos": tpos, "team": v.team})
	var vid := Melee.best_target({"pos": atk.pos, "yaw": atk.yaw, "team": atk.team}, enemies)
	if vid == 0: return
	var victim: Pawn = _sim.world.get_pawn(vid)
	var weapon_id := int(c.get("weapon", 0))
	# Rear-arc test against where the victim was seen (rewound), so a back-stab reads the same as on-screen.
	var vpos: Vector3 = lag_frame[vid]["pos"] if lag_frame.has(vid) else victim.pos
	if Melee.is_backstab(victim.yaw, atk.pos - vpos):
		# Rear-arc back-stab = instant kill: headshot=true routes through Revive.is_instant_kill,
		# bypassing DBNO (same path the M4.5 head/blast instant-kill uses).
		_apply_pawn_damage(vid, victim, 100000, true, Revive.Source.BULLET, id, weapon_id)
		_stats.backstabs += 1
	else:
		_apply_pawn_damage(vid, victim, melee_damage, false, Revive.Source.BULLET, id, weapon_id)
	_stats.melees += 1

func _handle_gadget_action(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive or p.is_downed or p.climbing: return   # no gadget/RPG/C4 while climbing
	var d := Protocol.decode_gadget_action(bytes)
	match int(d["action"]):
		Protocol.GA_RPG_FIRE: _fire_rocket(id, p, d["dir"])
		Protocol.GA_C4_PLACE: _place_c4(id, p, d["pos"])
		Protocol.GA_C4_DETONATE: _detonate_c4(id)
		Protocol.GA_MINE_PLACE: _place_mine(id, p, d["pos"], d["dir"])
		Protocol.GA_GIVE_START: _support.giving[id] = _sim.tick
		Protocol.GA_GIVE_STOP: _support.giving.erase(id)
		Protocol.GA_BAG_THROW: _throw_bag(id, p, d["pos"])
		Protocol.GA_REPAIR_START: _support.repairing[id] = true
		Protocol.GA_REPAIR_STOP: _support.repairing.erase(id)
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
	if v.team != p.team:
		v.team = p.team   # stealing an unoccupied enemy vehicle claims it for your team (no ownership)
	v.seats[seat] = id
	p.in_vehicle = vid
	p.seat = seat
	_stats.enters += 1
	_transport_origin[id] = v.pos   # for the transport-distance gate metric (Task 16)

func _vehicle_exit(id: int, p: Pawn) -> void:
	if p.in_vehicle == 0: return
	var v: Vehicle = _sim.world.vehicles.get(p.in_vehicle)
	if v != null:
		if p.seat >= 0 and p.seat < v.seats.size(): v.seats[p.seat] = 0
		p.pos = _safe_exit_pos(v)
	p.in_vehicle = 0
	p.seat = -1
	_stats.exits += 1
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
				_stats.transport_max = maxf(_stats.transport_max, dist)

## Launch an RPG rocket if the player has the RPG equipped, rockets remaining, and is off cooldown.
func _fire_rocket(id: int, p: Pawn, dir: Vector3) -> void:
	var c = _clients[id]
	if int(c["weapon"]) != Weapon.RPG: return
	if int(c["rockets"]) <= 0: return
	var rdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_RPG)
	var fast_rpg := _fast_rpg and not bool(c["auto_deploy"])   # HUMANS ONLY — never let bots' RPGs go on infinite fire
	if not fast_rpg and _sim.tick - int(c["last_rocket_tick"]) < int(rdef["cooldown_ticks"]): return
	if dir.length() < 0.001: return
	c["last_rocket_tick"] = _sim.tick
	if not fast_rpg:
		c["rockets"] = int(c["rockets"]) - 1
	_rockets.append({"owner": id, "team": p.team, "pos": p.eye_position(), "vel": dir.normalized() * float(rdef["rocket_speed"])})
	# Cosmetic: tell other humans a rocket launched so they render it flying. The shooter renders
	# its own immediately (client-side, no RTT wait) — mirrors the gunfire tracer split.
	_broadcast_rocket_fx(id, p.eye_position(), dir.normalized())

func _broadcast_rocket_fx(shooter_id: int, origin: Vector3, dir: Vector3) -> void:
	_broadcast_humans(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_rocket_fx(origin, dir), 0, shooter_id)

## Authoritative deployed-gadget list (C4/mines/bags) for humans to render AND (M7.5-P3) for bots'
## fair-play mine/bag awareness — same bytes a rendered client gets, not server-state reads. Rebuilt
## from the live stores each tick and sent (reliably) only when it CHANGES, plus a ~1 Hz heartbeat
## while non-empty so a late joiner catches up. Skipped entirely when nobody is connected.
## Perf: the ReliableList cadence is untouched — steady-state cost is the ~1 Hz heartbeat
## × N clients of one small reliable packet, encoded once.
func _broadcast_gadget_list() -> void:
	if _clients.is_empty():
		return
	var list := GadgetList.build(_c4, _mines, _bags)
	var pkt := Protocol.encode_gadget_list(list)
	if not _gadget_rl.should_send(pkt, list.size() > 0, _sim.tick):
		return
	_broadcast_all(NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

## Active support links (heal/ammo/repair/revive) for human clients to draw a beam + target aura.
## Same shape as the gadget list: rebuilt each tick from what the support steps actually acted on,
## sent reliably only when it CHANGES, plus a ~1 Hz heartbeat while non-empty for late joiners.
## Skipped entirely when no human is connected.
func _broadcast_support_list() -> void:
	if _human_ids.is_empty():
		return
	var list := SupportLinks.build(_support.links_this_tick)
	var pkt := Protocol.encode_support_list(list)
	if not _support_rl.should_send(pkt, list.size() > 0, _sim.tick):
		return
	_broadcast_humans(NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

## Downed pawns + their bleed-out urgency (M7 revive marker). Same change+heartbeat shape as the
## gadget/support lists; skipped when no human is connected. The list is naturally tiny (only DOWNED
## pawns), so it's cheap even at 128p. The client drives the revive marker colour/pulse from `frac`.
func _broadcast_downed_list() -> void:
	if _human_ids.is_empty():
		return
	var list: Array = []
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		if p.is_downed:
			list.append({"id": id, "frac": Revive.bleed_frac_u8(p.bleed_health, p.bleed_floor), "halted": p.bleed_halted})
	var pkt := Protocol.encode_downed_list(list)
	if not _downed_rl.should_send(pkt, list.size() > 0, _sim.tick):
		return
	_broadcast_humans(NetHost.CHANNEL_CONTROL, pkt, ENetPacketPeer.FLAG_RELIABLE)

## M12-P3: per-team FOB list (squad/structure_id/under_construction/enabled) for human clients to
## render. Same changed+heartbeat shape as the gadget/support/downed lists — this one used to send
## a RELIABLE packet to every human EVERY tick and recompute _spawnable_fob_pos per human.
func _send_fob_lists() -> void:
	if _human_ids.is_empty():
		return
	var pkts := {}
	var total := 0
	for team in [0, 1]:
		var list: Array = []
		for key in _build.fobs:
			var rec: Dictionary = _build.fobs[key]
			if int(rec["team"]) != team: continue
			var built: bool = bool(rec["built"])
			var enabled := false
			if built:
				enabled = _build.spawnable_fob_pos(team, int(rec["squad"])) != null
			list.append({"squad": int(rec["squad"]), "structure_id": int(rec["id"]),
				"under_construction": 0 if built else 1, "enabled": 1 if enabled else 0})
		total += list.size()
		pkts[team] = Protocol.encode_fob_list(list)
	if not _fob_rl.should_send(pkts, total > 0, _sim.tick):
		return
	for cid in _human_ids:
		var c = _clients[cid]
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, pkts[int(c["team"])], ENetPacketPeer.FLAG_RELIABLE)

## Remote thrown-grenade hint: cosmetic arc for humans AND (M7.5-P3) the bots' grenade-avoidance
## input — fair play, same packet a rendered client receives. Excludes the thrower (humans arc their
## own grenade from client_main; a bot knows its own throw). Unreliable/droppable like the other
## *_FX broadcasts, per-throw only (no steady-state cost); encoded once, sent N.
func _broadcast_grenade_fx(thrower_id: int, origin: Vector3, dir: Vector3, kind: int, team: int = 0, charge: float = 1.0) -> void:
	_broadcast_all(NetHost.CHANNEL_SNAPSHOT, Protocol.encode_grenade_fx(origin, dir, kind, team, charge), 0, thrower_id)

func _place_c4(id: int, p: Pawn, pos: Vector3) -> void:
	if Loadout.gadget_for_player(int(_clients[id]["class"]), id) != Loadout.GADGET_C4: return
	var cdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_C4)
	var owned: Array = _c4.get(id, [])
	if owned.size() >= int(cdef["max_active"]): return
	if p.pos.distance_to(pos) > StructureStore.BUILD_RANGE: return   # within reach
	# Keep the REAL cell (y layer included): _remove_c4_on_cell is keyed by the destroyed piece's
	# actual cell, so a y=0-flattened key left C4 floating when an elevated piece was destroyed.
	owned.append({"pos": pos, "cell": BuildGrid.cell_of(pos)})
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
	var kind := _support.giver_kind(int(_clients[id]["class"]))
	if kind == -1: return
	var gdef: Dictionary = _gadgets.def_of_kind(kind)
	var bag_count := 0
	for b in _bags:
		if int(b["owner"]) == id: bag_count += 1
	if bag_count >= int(gdef["max_bags"]): return
	if p.pos.distance_to(pos) > StructureStore.BUILD_RANGE: return   # within throwing reach, like C4/mine placement
	_bags.append({"owner": id, "team": p.team, "kind": kind, "pos": pos, "pool": int(gdef["bag_pool"])})
	_stats.bags_thrown += 1

## Maps a class to its give-tool kind (heal/ammo), or -1 if the class has no give tool.
func _detonate_c4(id: int) -> void:
	var owned: Array = _c4.get(id, [])
	if owned.is_empty(): return
	var cdef: Dictionary = _gadgets.def_of_kind(Gadget.KIND_C4)
	var team: int = _sim.world.get_pawn(id).team if _sim.world.get_pawn(id) != null else int(_clients[id]["team"])
	for c4 in owned:
		_stats.c4_det += 1
		_blast_at(c4["pos"], id, team, int(cdef["pawn_damage"]), float(cdef["pawn_radius"]),
			int(cdef["struct_damage"]), float(cdef["struct_radius"]), C4_VEHICLE_DMG)
		_broadcast_detonation(c4["pos"], Protocol.DET_EXPLOSION)   # blast VFX/audio (same as frag)
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
		if int(g["type"]) == Grenade.SMOKE:
			# Smoke integrates every tick (falls, rests on the ground). It begins billowing at the fuse
			# and then keeps emitting — the canister and its cloud stay live until the cloud lifetime
			# ends, so the cloud follows the grenade wherever it flies/tumbles to (C3). The grenade item
			# is only dropped from the pool once the smoke finishes.
			_integrate_grenade(g)
			if not bool(g.get("smoking", false)):
				if _sim.tick >= int(g["detonate_tick"]):
					_begin_smoke(g)
			else:
				g["zone"]["pos"] = g["pos"]   # cloud + LOS zone track the canister
				if _sim.tick >= int(g["smoke_until"]):
					continue   # cloud finished — drop the canister (zone expires via _expire_smoke_zones)
			still.append(g)
			continue
		# Frag / flashbang: airburst on the fuse, or blast on first ground contact.
		if _sim.tick >= int(g["detonate_tick"]):
			_detonate(g)
			continue
		_integrate_grenade(g)
		if g["pos"].y <= 0.0:
			_detonate(g)
		else:
			still.append(g)
	_grenades = still

## Integrate one live grenade one tick under the shared ballistic model, bouncing off structures and
## resting it on the ground. Shared by the frag ground-contact check and the smoke-canister follow.
const GRENADE_RESTITUTION := 0.45   # velocity retained after a wall bounce
const GRENADE_BOUNCE_SKIN := 0.15   # m; rest the grenade this far off the struck face so it can't re-embed
func _integrate_grenade(g: Dictionary) -> void:
	var s := Grenade.integrate(g["pos"], g["vel"], SimLoop.DT)
	var new_pos: Vector3 = s["pos"]
	# Bounce off structures instead of tunnelling through walls (frag + smoke). Impact grenades have
	# their own contact detonation in _step_impact and never come through here.
	if _store != null and _store.count() > 0:
		var seg: Vector3 = new_pos - (g["pos"] as Vector3)
		var seg_len := seg.length()
		if seg_len > 0.0001:
			var hit := _store.march_normal(g["pos"], seg / seg_len, seg_len)
			if bool(hit.get("hit", false)):
				var n: Vector3 = hit["normal"]
				var v: Vector3 = s["vel"]
				g["pos"] = (hit["point"] as Vector3) + n * GRENADE_BOUNCE_SKIN
				g["vel"] = (v - 2.0 * v.dot(n) * n) * GRENADE_RESTITUTION   # reflect + lose energy
				if g["pos"].y <= 0.0:
					g["pos"].y = 0.0
					g["vel"] = Vector3.ZERO
				return
	g["pos"] = new_pos; g["vel"] = s["vel"]
	if g["pos"].y <= 0.0:
		g["pos"].y = 0.0
		g["vel"] = Vector3.ZERO

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
		_stats.impacts += 1
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
	_stats.veh_destroyed += 1
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
			_stats.rockets_det += 1
			_stats.rstruct += _store.ids_in_radius(nxt, float(rdef["struct_radius"])).size()
			for vid in _sim.world.vehicles:
				var vv: Vehicle = _sim.world.vehicles[vid]
				if vv.alive and vv.team != int(r["team"]) and nxt.distance_to(vv.pos) <= float(rdef["pawn_radius"]):
					_stats.rkt_vs_veh += 1
			_blast_at(nxt, int(r["owner"]), int(r["team"]),
				int(rdef["pawn_damage"]), float(rdef["pawn_radius"]),
				int(rdef["struct_damage"]), float(rdef["struct_radius"]), RPG_VEHICLE_DMG)
			_broadcast_detonation(nxt, Protocol.DET_EXPLOSION)   # blast at the TRUE impact (client culls its fly-through cosmetic rocket)
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
			_stats.mine_trips += 1
			_blast_at(m["pos"], int(m["owner"]), int(m["team"]), int(mdef["pawn_damage"]),
				float(mdef["pawn_radius"]), 0, 0.0)
			_broadcast_detonation(m["pos"], Protocol.DET_EXPLOSION)   # blast VFX/audio (same as frag)
		else:
			still.append(m)
	_mines = still

## Frag: area damage at the grenade's current position — structures (cell radius) + pawns (sphere,
## current positions, FF-off incl. thrower). Removes/chunk-mask deltas route through _damage_structure.
## (Smoke is handled by a branch added in Task 9.)
func _detonate(g: Dictionary) -> void:
	if int(g["type"]) == Grenade.SMOKE:
		_begin_smoke(g)   # defensive: smoke normally billows via _step_grenades, never through _detonate
		return
	if int(g["type"]) == Grenade.FLASHBANG:
		_detonate_flash(g)
		_broadcast_detonation(g["pos"], Protocol.DET_FLASH)
		return
	_stats.nades += 1
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
	_stats.flashes += 1
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
		_stats.flash_blinds += 1

## Smoke begins billowing (no damage). Records a server-side zone (referenced back on the grenade so
## _step_grenades can move it as the canister falls/rests — M7 LOS culling reads _smoke_zones) and
## broadcasts the deploy once, carrying the canister's pop position + velocity so the client integrates
## the same fall and the cloud follows the grenade. Low-frequency (bounded by the throw cooldown).
func _begin_smoke(g: Dictionary) -> void:
	if bool(g.get("smoking", false)):
		return
	_stats.smokes += 1
	g["smoking"] = true
	g["smoke_until"] = _sim.tick + SMOKE_DURATION_TICKS
	var zone := {"pos": g["pos"], "radius": SMOKE_RADIUS, "expire_tick": int(g["smoke_until"])}
	_smoke_zones.append(zone)
	g["zone"] = zone
	var bytes := Protocol.encode_smoke_deployed(g["pos"], SMOKE_RADIUS, int(g["smoke_until"]), g["vel"])
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
				_stats.heals += 1
			else:
				# Ammo bag: top up at most once per active period, costing 1 pool (mag).
				if _sim.tick % maxi(1, int(gdef["active_rate"]) * 4) != 0: continue
				if not _clients.has(pid): continue
				var tc = _clients[pid]
				var cap: int = int(Weapon.get_def(int(tc["weapon"]))["mag_size"])
				if int(tc["ammo"]) >= cap: continue
				tc["ammo"] = cap
				dispensed += 1
				_stats.ammo_gives += 1
		if dispensed > 0:
			b["pool"] = Gadget.decrement_pool(int(b["pool"]), dispensed)
		if int(b["pool"]) <= 0:
			_stats.bags_exhausted += 1
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
	_stats.dmg += 1
	if res["destroyed"]:
		_stats.destroyed += 1
		_pending_removes.append({"id": id, "cell": cell})
		_dmg_touched.erase(id)
		_remove_c4_on_cell(cell)
		if bid != 0 and structural:
			_buildings_to_cascade[bid] = true
	else:
		_dmg_touched[id] = true

## Fully collapse one building: drop every remaining piece (and any C4 stuck to them), remove its
## roof ladders (H1), broadcast COLLAPSE, and record the id so late joiners get the collapse
## replayed at welcome (A3 ghost-ladder fix). Called by the cascade resolver and --collapse-test.
const COLLAPSE_CRUSH_MARGIN := 1.5   # m: the "inside or very close" band around the footprint that a collapse crushes
func _collapse_building(bid: int) -> void:
	if _collapsed_bids.has(bid):
		return   # idempotent: the cascade resolver and the empty-building path can both target one bid
	# Capture the footprint from the live pieces BEFORE we drop them — it's the crush volume.
	var cells: Array = []
	for oid in _store.ids_of_building(bid):
		var crec := _store.get_record(oid)
		if not crec.is_empty():
			cells.append(crec["cell"])
			_remove_c4_on_cell(crec["cell"])
		_dmg_touched.erase(oid)
		_store.remove(oid)
	_apply_collapse_crush(CollapseZone.bounds(cells, COLLAPSE_CRUSH_MARGIN))
	_stats.collapsed += 1
	# H1: the building is gone — remove its roof ladder(s) so nobody climbs a ghost into thin air.
	var kept_ladders: Array = []
	for ld in _sim.ladders:
		if int(ld.get("building_id", 0)) != bid:
			kept_ladders.append(ld)
	_sim.ladders = kept_ladders
	var bytes := Protocol.encode_collapse(bid)
	for cid in _clients:
		_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
	_collapsed_bids.append(bid)   # so a late joiner's welcome replays this collapse (ghost ladders)

## Collapse lethality: a building coming down crushes everything inside/very-close to its footprint —
## every pawn (any team; environmental, self-attributed like a fall), any vehicle, and deployed gear
## (C4/mines/bags). Vehicles first so their occupants die via the vehicle path; then loose pawns.
func _apply_collapse_crush(zone: Dictionary) -> void:
	if zone.is_empty():
		return   # already-emptied building (no live pieces) — nothing physically fell to crush anyone
	for vid in _sim.world.vehicles.keys():
		var v: Vehicle = _sim.world.vehicles[vid]
		if v != null and v.hp > 0 and CollapseZone.contains(zone, v.pos):
			_destroy_vehicle(vid, v, 0)   # killer 0 = environmental (no client, so no kill credit)
	for pid in _sim.world.pawns.keys():
		var pawn: Pawn = _sim.world.pawns[pid]
		if pawn == null or not pawn.alive or pawn.in_vehicle > 0:
			continue   # dead already, or seated (handled by the vehicle crush above)
		if CollapseZone.contains(zone, pawn.pos):
			_kill_pawn(pid, pawn, pid, 0, false, Revive.Source.BLAST)   # self-attributed -> no kill awarded
	_mines = _mines.filter(func(m): return not CollapseZone.contains(zone, m["pos"]))
	_bags = _bags.filter(func(b): return not CollapseZone.contains(zone, b["pos"]))

## After this tick's structural removals, orphan-check each touched building. Large orphan sets
## collapse the whole building (one COLLAPSE broadcast); small sets queue per-piece removes.
func _resolve_cascades() -> void:
	if _buildings_to_cascade.is_empty():
		return
	for bid in _buildings_to_cascade.keys():
		var orphans := Support.orphaned_after(_store, bid, [])
		if Support.should_collapse(orphans.size()):
			_collapse_building(bid)
			continue
		for oid in orphans:
			var orec := _store.get_record(oid)
			if orec.is_empty():
				continue
			var ocell: Vector3i = orec["cell"]
			_remove_c4_on_cell(ocell)
			_store.remove(oid)
			_pending_removes.append({"id": oid, "cell": ocell})
			_dmg_touched.erase(oid)
		# A building whittled down to no pieces (by this tick's orphan removal OR by direct damage that
		# left no orphans to cascade) is effectively gone — collapse it so its roof ladders are freed and
		# the empty state replays to late joiners. Without this those ladders floated on "destroyed but
		# not collapsed" buildings (playtest: far ghost ladders after reconnect).
		if _store.ids_of_building(bid).is_empty():
			_collapse_building(bid)
	_buildings_to_cascade.clear()

## Flush queued removes + chunk-mask deltas to interested clients, bounded by
## MAX_STRUCTURE_DELTAS_PER_TICK (removes first; overflow carried to next tick). Authoritative
## state is already applied — only the SEND volume is throttled. See docs/specs/destructible-buildings.md.
func _emit_structure_deltas() -> void:
	var budget := MAX_STRUCTURE_DELTAS_PER_TICK
	while not _pending_removes.is_empty() and budget > 0:
		var r: Dictionary = _pending_removes.pop_front()
		_stats.removes += 1
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
	if _store.count() == 0 and _build.sites.count() == 0:
		return
	var center := _grid.key_of(self_pos)
	var span := int(ceil(INTEREST_RADIUS / CELL_SIZE))
	var known: Dictionary = c["known_regions"]
	# Collect the unknown, non-empty regions in interest range with their piece count + distance, then
	# let the pacer pick a nearest-first subset within the per-tick budget (the rest stream next tick).
	var candidates: Array = []
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var region := Vector2i(center.x + dx, center.y + dz)
			if known.has(region):
				continue
			var pieces := _store.region_count(region) + _build.sites.region_count(region)
			if pieces == 0:
				continue   # empty region: leave unknown (cheap to re-check; may gain pieces via deltas)
			var rc := _grid.world_of_key(region)   # region centre, for nearest-first ordering
			candidates.append({"region": region, "pieces": pieces, "dist2": self_pos.distance_squared_to(rc)})
	for sel in BaselinePacer.pick(candidates, MAX_STRUCTURE_BASELINE_PIECES_PER_TICK):
		var region: Vector2i = sel["region"]
		var recs := _store.records_in_region(region)
		for s in _build.sites.records_in_region(region):
			recs.append(_build.site_wire_record(s))
		known[region] = true
		var bytes := Protocol.encode_structure_baseline(region, recs)
		_net.send_to(c["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

## Free the pawn's vehicle seat (shared by death and disconnect). Without it a ghost
## occupant id stays in v.seats forever — an undrivable vehicle and wrong free_seats.
func _vacate_seat(p: Pawn) -> void:
	if p.in_vehicle == 0:
		return
	var seated_veh: Vehicle = _sim.world.vehicles.get(p.in_vehicle)
	if seated_veh != null and p.seat >= 0 and p.seat < seated_veh.seats.size():
		seated_veh.seats[p.seat] = 0
	p.in_vehicle = 0
	p.seat = -1

func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0 and _clients.has(id):
		var team: int = _clients[id]["team"]
		_team_counts[team] -= 1
		_squads.remove(id, team)
		var pawn: Pawn = _sim.world.get_pawn(id)
		if pawn != null:
			_vacate_seat(pawn)
		_transport_origin.erase(id)
		_human_ids.erase(id)
		_clients.erase(id)
		_sim.world.despawn(id)
		_prev_climb_vault.erase(id)
		# Drop the leaver's deployed gadgets: their C4 can never be detonated again (handler needs the
		# client) and orphaned entries would render + ride the GADGET_LIST heartbeat for the whole match.
		_c4.erase(id)
		var kept_mines: Array = []
		for m in _mines:
			if int(m["owner"]) != id: kept_mines.append(m)
		_mines = kept_mines
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var pts := ""
	for pt in _conquest.points:
		pts += "." if pt["owner"] == -1 else str(pt["owner"])
	# Mean per-peer packet loss (ENet rolling stat) — network-health observability under load (M8-P2).
	var losses: Array = []
	for id in _clients:
		var peer: ENetPacketPeer = _clients[id].get("peer")
		if peer != null:
			losses.append(peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS))
	var pktloss := Telemetry.mean_packet_loss_pct(losses)
	print(_stats.telemetry_line(n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit,
		pktloss, _tele.starvation, _conquest.tickets_int(0), _conquest.tickets_int(1), pts,
		_store.count()))
	var pt := maxi(_phase_ticks, 1)
	print("[perf] us/tick: poll=%d move=%d veh=%d lag=%d interest=%d fire=%d ordnance=%d support=%d build=%d respawn=%d conquest=%d match=%d snap=%d (ticks=%d)"
		% [_phase_us["poll"] / pt, _phase_us["move"] / pt, _phase_us["veh"] / pt, _phase_us["lag"] / pt, _phase_us["interest"] / pt, _phase_us["fire"] / pt, _phase_us["ordnance"] / pt, _phase_us["support"] / pt, _phase_us["build"] / pt, _phase_us["respawn"] / pt, _phase_us["conquest"] / pt, _phase_us["match"] / pt, _phase_us["snap"] / pt, _phase_ticks])
	# M8-P3 adaptive degradation: re-evaluate the ladder off this window's mean tick (before reset).
	var new_level := Degrade.next_level(_tele.mean_tick_ms(), _degrade_level, _degrade_high_ms, _degrade_low_ms)
	if new_level != _degrade_level:
		_degrade_level = new_level
		_snapshot_stride = Degrade.stride_for(new_level)
		_max_enemy_snapshot = Degrade.enemy_cap_for(new_level)
		print("[degrade] level=%d tick_mean=%.2fms -> snapshot_stride=%d max_enemy_snapshot=%d"
			% [new_level, _tele.mean_tick_ms(), _snapshot_stride, _max_enemy_snapshot])
	for k in _phase_us: _phase_us[k] = 0
	_phase_ticks = 0
	_tele.reset_window()
	_stats.reset_window()
