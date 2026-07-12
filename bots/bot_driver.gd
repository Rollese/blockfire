class_name BotDriver
extends Node
## Headless bot fleet. Each bot is a real client that decodes its interest view and
## fights the nearest enemy. Many bots per process (load + playtest). See M2 spec.

const Protocol := preload("res://shared/net/protocol.gd")
const MAP_PATH := "res://maps/conquest_proving_grounds.json"   # default; override with --map=<name>
const BUILD_COOLDOWN_TICKS := 150   # match server StructureStore.BUILD_COOLDOWN_TICKS (5s)
const BUILD_DIST := 3.0             # how far ahead (m) to drop cover; within server BUILD_RANGE
const MAX_BOT_BUILDS := 3           # per-bot lifetime BUILD_REQUEST cap. Re-enabled (was 0) so the
                                    # M12-P2 shovel-drillers (BotRoles.SHOVEL) can PLACE build sites and
                                    # the fleet gate sees built_small/built_large/bsolo/dismantled/repaired.
                                    # Normal bots only drop a side-wall while stationary (original gate
                                    # behaviour); 3 is a small cap so it does not clutter combat.
const PIECES_PATH := "res://pieces/pieces.json"   # match server PIECES_PATH (shovel-drill type lookup)
const WALL_TYPE := 1                # small piece (min_builders 1) shovel-drillers build solo
const SHOVEL_APPROACH := BuildSite.SHOVEL_RANGE * 0.8   # stop+shovel once this close to the site centre
const BUILD_COMMIT_TICKS := 90     # ticks a driller stays on a just-placed cell awaiting its site delta
const SHOVEL_SEEK_RANGE := 28.0    # m: build-capped drillers roam to a structure within this to repair/dismantle
const SMALL_LANES := 13            # per-team lane slots a small driller scans for a clear near-base build cell
const SMALL_BUILD_DEPTH := 6.0     # m in front of the base (toward map centre) where small build lanes sit
const GRENADE_COOLDOWN_TICKS := 300   # match server GRENADE_COOLDOWN_TICKS (10s, shared frag/smoke)
const MAX_BOT_GRENADES := 1           # per-bot lifetime FRAG cap (convergence/over-destruction knob)
const MAX_BOT_SMOKES := 1             # per-bot lifetime SMOKE cap (exercises the smoke path)
const MAX_BOT_SPECIAL_THROWS := 3     # per-bot lifetime FLASHBANG/IMPACT cap (M5.5-P3 gate exerciser)
const MELEE_COOLDOWN_TICKS := 24      # match server MELEE_COOLDOWN_TICKS (~0.8s)
const SLEDGE_SEEK_RANGE := 10.0       # m — engineer sledgers steer to a structure within this range
const BotRolesRef := preload("res://bots/roles.gd")   # disjoint exerciser role table
const BotExercisers := preload("res://bots/exercisers.gd")
const VEHICLE_FULL_HP := 600       # transport max (v1 single vehicle type); used to detect a damaged ridden vehicle
const VEHICLE_RPG_RANGE := 120.0   # fire an RPG at an enemy vehicle within this many metres
const RPG_FIRE_COOLDOWN := 120     # ticks between RPG fire attempts (matches server cooldown_ticks)
# Structure-directed RPG restraint (bot-ai.md §8 balance gap): with vehicles removed from every
# shipping map, the anti-vehicle RPG always fell through to the building fallback and rocketed the
# nearest wall every RPG_FIRE_COOLDOWN for the whole match (~815 rockets/28 min, ~27% of the map
# wrecked). Bots now rocket a wall only when an enemy is actually using it as cover, and on a much
# longer cadence than the anti-vehicle path — un-BattleBit-like map demolition, tempered.
const RPG_STRUCTURE_COOLDOWN := 600      # ticks (~20 s @30Hz) between structure-directed rockets
const RPG_STRUCTURE_ENEMY_RADIUS := 6.0  # m: only rocket a piece with a visible enemy this close to it
# M19 P2b Task 6: BREACH restraint (bot-ai.md §8 lesson applied up front, not after the fact — see
# project memory blockfire-bot-rpg-restraint). A BREACH bot must place VERY rarely and only when a
# wall is genuinely blocking its own march to the objective, so it never reads as spam-carving.
const BREACH_PLACE_RANGE := 2.5          # m — mirrors data/gadgets.json breach.place_range
const BREACH_COOLDOWN_TICKS := 1800      # ticks (~60 s @30Hz) — stricter than RPG_STRUCTURE_COOLDOWN
const MAX_BOT_BREACHES := 1              # per-bot MATCH-lifetime cap (never reset on respawn)
const REPAIR_STRUCT_RANGE := 4.0         # m — mirrors data/gadgets.json repair.range; harmless no-op
                                          # when the aimed piece is already full (server repair_chunks)
# M19 P2b Task 7: STIM/SMOKE_WALL restraint. STIM is a harmless self-buff (server already gates
# charges + a 30-tick use_cooldown_ticks), so the bot can be liberal — but a per-bot cadence still
# stops it hammering the action every tick while it sits in the qualifying window. SMOKE_WALL
# alters LOS for both teams, so it gets BREACH-style restraint: a small per-bot MATCH-lifetime cap
# plus a long cooldown, only placed while advancing with no immediate enemy in view.
const STIM_BOT_COOLDOWN_TICKS := 90       # ticks (~3 s @30Hz) — bot-side pacing atop the server's own gate
const STIM_HURT_HEALTH := 60              # HP at/below which a stim bot self-injects even out of combat
const SMOKE_WALL_PLACE_RANGE := 2.3       # m — just inside data/gadgets.json smokewall.place_range (2.5)
const SMOKE_WALL_COOLDOWN_TICKS := 1800   # ticks (~60 s @30Hz) — matches BREACH_COOLDOWN_TICKS restraint
const MAX_BOT_SMOKE_WALLS := 1            # per-bot MATCH-lifetime cap (never reset on respawn)
const ROCKET_SPEED := 150.0  # keep in sync with data/gadgets.json rpg.rocket_speed (bot lead math)
const ROCKET_GRAVITY := 20.0  # matches Grenade.GRAVITY; bots aim higher by 1/2 g t^2 to counter rocket drop
const FOB_DRILL_MAX_TICKS := 30 * 30   # M12-P3: safety deadline (~30s) a squad leader drills its FOB
                                       # before giving up and falling through to normal AI (placement
                                       # may keep failing on a contested/occupied cell — don't babysit).
const MAX_GRENADE_EVENTS := 8      # M7.5-P3: grenade-landing ring size (oldest dropped)
const GRENADE_LANDING_EST := 8.0   # m ahead of the throw origin — flat landing estimate; the
                                   # cosmetic arc flies ~1.5s at the server throw speed, so 8m
                                   # matches well enough for avoidance (plan Task 6)
const BAG_NEEDY_RANGE := 12.0      # m: allies this close and hurt count toward a bag deploy
const BAG_NEEDY_HP := 60           # hp below this (0.6 frac) marks an ally as needy
const BANDAGE_SAFE_DIST := 18.0    # m: a bleeding bot self-bandages when no enemy is closer than this (M16)
const GIVEUP_NO_HELP_RADIUS := 20.0   # m: a downed bot with no alive friendly this close gives up (no reviver coming)
const RECONNECT_DELAY_FRAMES := 90    # ~3s before re-dialling after a server disconnect (rotation boundary)
const BOARD_RETRY_TICKS := 30         # min ticks between VA_ENTER attempts while the seat isn't confirmed
const BOARD_MAX_TRIES := 3            # rejected boards of one hull before we blacklist it and fight on foot
const BOARD_BLACKLIST_TICKS := 600    # ~20s a refused hull stays ignored

# M19 P4 Task 14: SUPPORT LMG-nest exerciser (bots/exercisers.gd maybe_lmg_nest + drive_mounted_nest).
# ~1/3 of Support bots roll GADGET_LMG_NEST (Loadout.bot_gadget id%3==1), so the fleet gate exercises
# the deploy -> mount -> fire -> dismount loop. DEPLOY is cadence-gated (a Support drops a nest
# occasionally when facing enemies — never spam, mirroring the BREACH/SMOKE_WALL restraint), MOUNT is
# retry-gated like the vehicle board, and a mounted gunner is seat-locked so it only aims + holds fire.
const LMG_NEST_DEPLOY_COOLDOWN_TICKS := 900   # ~30 s @30Hz between deploy attempts (occasional, not per-tick)
const LMG_NEST_DEPLOY_AHEAD := 2.5            # m ahead of facing to place it (seat ends ~1.9 m ahead — walkable into mount range)
const LMG_NEST_NEAR_RADIUS := 6.0             # m — a friendly nest this close means "use it / don't redeploy"
const LMG_NEST_MOUNT_RANGE := 1.6             # m — must match data/gadgets.json lmgnest.mount_range_m (mount seek == server gate)
const LMG_MOUNT_RETRY_TICKS := 30             # min ticks between EA_MOUNT attempts (mirrors BOARD_RETRY_TICKS)
const LMG_NEST_DISMOUNT_NOTARGET_TICKS := 150 # ~5 s with no live target -> dismount and rejoin the push
const LMG_NEST_FIRE_ARC := deg_to_rad(45)     # rad — MUST match data/gadgets.json lmgnest.half_arc_deg: the
                                              # server pins the turret to ±half_arc (Emplacement.clamp_yaw) and
                                              # fires along that clamped yaw, so a target beyond it is unhittable —
                                              # opening fire there just wastes the belt at the arc edge.

# M19 P5 Task 7: SUPPORT riot-shield exerciser (bots/exercisers.gd maybe_riot_shield). ~1/3 of Support
# bots roll GADGET_RIOT_SHIELD (Loadout.bot_gadget id%3==2), so the fleet gate exercises the shield's
# frontal-block/break paths (server/stats.gd shield_blocks/shield_breaks). Restrained by construction —
# no cadence needed: it only raises while a live enemy is close AND already roughly ahead of the bot's
# current combat facing, so it toggles off the moment the fight moves on (never a permanent turtle).
const RIOT_SHIELD_ENGAGE_RANGE := 20.0        # m — only worth raising the (speed-penalized) shield this close to a fight
const RIOT_SHIELD_FRONT_ARC := deg_to_rad(90) # rad — half-angle off the bot's CURRENT facing counted as "roughly ahead"

## M15: bot-only slope-avoidance (NOT pathfinding, NOT sim-authoritative — the server still
## authoritatively clips a bot's movement via Terrain.resolve_movement exactly like a human; see
## shared/sim/sim_loop.gd). A too-steep hill otherwise sticks a bot's AI in place forever since it
## keeps commanding the same blocked heading. These two pure helpers detect that and pick a lateral
## heading to escape along; wiring lives in _update_slope_avoid below.
const SLOPE_STUCK_RATIO := 0.25   # advanced < 25% of commanded travel while trying -> stuck
const SLOPE_WINDOW_TICKS := 15    # ticks of commanded-vs-actual history before judging "stuck"
const SLOPE_OVERRIDE_TICKS := 18  # ticks a latched sidestep heading holds before re-evaluating
const SLOPE_NOMINAL_SPEED := 5.0  # m/s estimate used only to scale the commanded-distance heuristic

## True when the bot commanded `commanded` metres of horizontal travel but only achieved `actual`.
static func is_slope_stuck(commanded: float, actual: float) -> bool:
	return commanded > 0.5 and actual < commanded * SLOPE_STUCK_RATIO

## Pick a sidestep heading when blocked: sample slope slightly ahead along two candidate headings —
## left-and-back / right-and-back diagonals off `heading` — and steer toward the shallower one.
## Two cheap extra samples, no search. Blending a small retreat component (rather than probing
## purely perpendicular) matters on a straight cliff face: that terrain is uniform along the
## sideways axis, so a pure-lateral probe ties forever at the same unwalkable slope and never
## finds the escape a step further back would reveal. Returns a unit XZ dir.
static func slope_sidestep(grid: TerrainGrid, pos: Vector3, heading: Vector3) -> Vector3:
	var h := Vector3(heading.x, 0.0, heading.z).normalized()
	if h == Vector3.ZERO:
		return heading
	var perp := Vector3(-h.z, 0.0, h.x)   # left perpendicular (XZ)
	var probe := (grid.spacing * 1.5) if grid != null else 3.0
	var left_dir := (perp - h).normalized()
	var right_dir := (-perp - h).normalized()
	var left := pos + left_dir * probe
	var right := pos + right_dir * probe
	var sl := Terrain.slope_at(grid, left.x, left.z)
	var sr := Terrain.slope_at(grid, right.x, right.z)
	return left_dir if sl <= sr else right_dir

## M-nav: bot-only building/wall avoidance (still NOT sim-authoritative — the server clips movement
## regardless; this only steers the AI's commanded heading so it stops burying itself in a wall).
## The slope sidestep above samples TERRAIN slope only, so a bot pressed flat against a building on
## level ground reads both sides as equally walkable and blindly shuffles left into the corner. This
## instead reads the nearby structure cells and escapes toward the CLEARER side, sliding around the
## footprint. Pure + unit-tested; wired from _update_slope_avoid when the stall isn't a slope.
const OBSTACLE_SCAN_RADIUS := 6.0     # m: structure cells this close count as walking obstacles
const OBSTACLE_VERTICAL_BAND := 3.0   # m: ignore cells more than a floor above/below the feet
const OBSTACLE_SIDESTEP_PROBE := 2.4  # m (one cell) ahead-of-lateral to sample clearance at
const OBSTACLE_RETREAT_BLEND := 0.5   # backpedal folded into the lateral escape (< the slope sidestep's

## Pick a sidestep heading around solid structures: sample clearance a probe-step down each lateral
## (left / right off `heading`, each folded with a small retreat so a flush press still yields lateral
## travel) and steer toward the side whose nearest obstacle is farther away. Pure. `obstacles` are
## world-space cell centres (see nearby_obstacle_cells). Returns a unit XZ dir (heading if degenerate).
static func obstacle_sidestep(pos: Vector3, heading: Vector3, obstacles: Array) -> Vector3:
	var h := Vector3(heading.x, 0.0, heading.z).normalized()
	if h == Vector3.ZERO:
		return heading
	var perp := Vector3(-h.z, 0.0, h.x)   # left perpendicular (XZ)
	var left_dir := (perp - h * OBSTACLE_RETREAT_BLEND).normalized()
	var right_dir := (-perp - h * OBSTACLE_RETREAT_BLEND).normalized()
	var lc := _min_clearance(pos + left_dir * OBSTACLE_SIDESTEP_PROBE, obstacles)
	var rc := _min_clearance(pos + right_dir * OBSTACLE_SIDESTEP_PROBE, obstacles)
	return left_dir if lc >= rc else right_dir   # tie -> left (stable)

## Nearest obstacle distance (XZ) to `p`, or INF when there are none. Pure helper for obstacle_sidestep.
static func _min_clearance(p: Vector3, obstacles: Array) -> float:
	var best := INF
	for o in obstacles:
		var ov: Vector3 = o
		var d := Vector2(ov.x - p.x, ov.z - p.z).length()
		if d < best:
			best = d
	return best

## World-space centres of the structure cells near `pos` on the walking floor: within
## OBSTACLE_SCAN_RADIUS horizontally and OBSTACLE_VERTICAL_BAND vertically (so upper storeys of a
## tall building don't count as ground obstacles). `structs` is the bot's synced sid -> record map.
## Pure + unit-tested.
static func nearby_obstacle_cells(structs: Dictionary, pos: Vector3) -> Array:
	var out: Array = []
	for sid in structs:
		var cell: Vector3i = structs[sid]["cell"]
		var w := BuildGrid.world_of(cell)
		if absf(w.y - pos.y) > OBSTACLE_VERTICAL_BAND:
			continue
		if Vector2(w.x - pos.x, w.z - pos.z).length() <= OBSTACLE_SCAN_RADIUS:
			out.append(w)
	return out

## True if an alive, non-downed friendly is within GIVEUP_NO_HELP_RADIUS of a downed bot — i.e. a
## revive is plausible, so it should wait rather than give up. `view` = pawn_id -> EntityState.
static func _reviver_near(view: Dictionary, self_id: int, my_team: int, my_pos: Vector3) -> bool:
	var r2 := GIVEUP_NO_HELP_RADIUS * GIVEUP_NO_HELP_RADIUS
	for id in view:
		if int(id) == self_id:
			continue
		var e: EntityState = view[id]
		if e != null and e.alive and not e.is_downed and e.team == my_team \
				and my_pos.distance_squared_to(e.pos) <= r2:
			return true
	return false

var _map: MapDef
var _terrain: TerrainGrid   # M15: built once from _map at load (and on map-rotation adopt); null on a flat map
var _map_path: String = MAP_PATH   # --map=<name> overrides (must match server + client)
var _match_points: Array = []   # array of {owner, attacker, cap}, index == map point index
var _synced_logged := false   # logs once when any bot first sees a structure (gate signal)

var _server_ip := "127.0.0.1"
var _port := 27015
var _bot_count := 1
var _bots: Array[Dictionary] = []
var _ex := BotExercisers.new(self)   # gate exercisers — see bots/exercisers.gd
var _global_seed: int = 12345
var _ai_profile := "regular"   # --ai-profile=<recruit|regular|veteran|elite> (M7.5-P3 §E)

var _perf_us: float = 0.0
var _perf_frames: int = 0

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_bot_count = maxi(1, int(args.get("bot-count", _bot_count)))
	_global_seed = int(args.get("seed", _global_seed))
	if args.has("map"):
		_map_path = "res://maps/%s.json" % String(args["map"])
	# M7.5-P3 (§E): difficulty profile every spawned AiDriver loads. Validate against the
	# tuning file so a typo degrades loudly to regular instead of silently using AiDriver's
	# fallback profile dict.
	var prof := String(args.get("ai-profile", "regular"))
	var tuning := AiTuning.load_file("res://data/ai_tuning.json")
	if tuning.get("profiles", {}).has(prof):
		_ai_profile = prof
	else:
		push_warning("[bots] unknown --ai-profile '%s' — using 'regular'" % prof)
		_ai_profile = "regular"

func _ready() -> void:
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[bots] failed to load map %s" % _map_path)
	# M15: view-only heightmap grid for the bot-only slope-avoidance heuristic (_update_slope_avoid).
	# Same helper + inputs the server uses (Terrain.load_for_map); a null map or a flat map (no
	# "terrain" block) yields a null grid and slope-avoidance simply never triggers.
	_terrain = Terrain.load_for_map(_map, "res://maps", Callable())
	print("[bots] spawning %d bot(s) -> %s:%d" % [_bot_count, _server_ip, _port])
	print("[bots] ai seed=%d" % _global_seed)
	# Deterministic bot headings for reproducible gate runs (seed wired from --seed).
	seed(hash(_global_seed))
	for i in _bot_count:
		_spawn_bot(i)

func _spawn_bot(index: int) -> void:
	var net := NetHost.new()
	add_child(net)
	var bot := {
		"net": net, "index": index, "id": 0, "connected": false, "peer": null,
		"tick": 0, "last_seq": 0, "server_tick": 0, "view": {},
		"yaw": randf() * TAU, "pitch": 0.0, "heading": randf() * TAU, "turn_timer": 0.0,
		"reload_until": 0, "burst_start": -1,
		"last_build_tick": -100000, "structs": {}, "builds_made": 0,
		"last_fob_tick": -100000, "fob_drill_start": -1,
		"last_grenade_tick": -100000, "nades_thrown": 0, "smokes_thrown": 0,
		"flashes_thrown": 0, "impacts_thrown": 0, "last_melee_tick": -100000,
		"class": 0, "rpg_last_tick": -100000, "rpg_struct_last_tick": -100000, "c4_placed": false, "c4_detonated": false,
		"mine_placed": false, "gave_until": 0, "give_target": 0,
		"vview": {}, "in_vehicle": 0, "boarded_origin": Vector3.ZERO, "repairing": false,
		"vveh_track": {},
		# M19 P2b Task 6: BREACH is a MATCH-lifetime cap (never reset on respawn, mirroring
		# nades_thrown/smokes_thrown below) — deliberately rarer than a per-life cap. struct_repairing
		# is per-life (reset on respawn, like the vehicle-crew "repairing" latch above) since
		# structure repair is harmless (no-op on an already-full piece).
		"breach_last_tick": -100000, "breaches_placed": 0, "struct_repairing": false,
		# M19 P2b Task 7: STIM cooldown is per-life (reset on respawn below, mirroring
		# struct_repairing) since a fresh life gets a fresh 3-charge pool from the server
		# (_apply_loadout_to_client). SMOKE_WALL is a MATCH-lifetime cap, mirroring breaches_placed,
		# since it alters LOS and must stay rare across the whole match, not per life.
		"stim_last_tick": -100000,
		"smoke_wall_last_tick": -100000, "smoke_walls_placed": 0,
		# M19 P4 Task 14: LMG-nest mirror + exerciser cadence state. `nests` is the wholesale
		# EMPLACEMENT_LIST mirror (refreshed each tick like `gadgets`); the *_tick fields pace deploy /
		# mount (persist across lives — they are cooldowns, not per-life caps); `lmg_notarget_since`
		# tracks how long a mounted gunner has lacked a target (dismount trigger), reset on death.
		"nests": [], "lmg_deploy_last_tick": -100000, "lmg_mount_last_tick": -100000, "lmg_notarget_since": -1,
		# M7.5-P3 support mirrors + latches: SELF_STATE dict, GADGET_LIST wholesale mirror,
		# GRENADE_FX landing ring; reviving_id = active REVIVE_ACTION latch,
		# last_bag_tick = needs-driven bag-deploy cooldown.
		"self_state": {}, "gadgets": [], "grenade_events": [],
		"reviving_id": 0, "last_bag_tick": -100000,
		# M15: slope-avoidance window/override state — see _update_slope_avoid.
		"slope_window_tick": -1, "slope_window_pos": Vector3.ZERO, "slope_commanded": 0.0,
		"slope_override_until": -1, "slope_override_dir": Vector2.ZERO,
		"ai": AiDriver.new(_global_seed, index, _ai_profile),
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	# Server-initiated disconnect (map rotation's disconnect_all, restart, kick): schedule a
	# reconnect instead of idling forever — the whole fleet used to go permanently inert at the
	# first rotation boundary. Staggered by index so 100+ bots don't reconnect on the same frame.
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void:
		bot["connected"] = false
		bot["peer"] = null
		bot["reconnect_in"] = RECONNECT_DELAY_FRAMES + int(bot["index"]) * 3)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void: _on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)

## Fresh dial + clean per-connection state after a server disconnect. The bot keeps its identity
## (index/AI instance) but every server-derived mirror is stale — the next match may be a different
## map with new entity ids, so drop them all and let WELCOME/baselines rebuild.
func _reconnect(bot: Dictionary) -> void:
	var net: NetHost = bot["net"]
	net.close()
	bot["id"] = 0
	bot["peer"] = null
	bot["view"] = {}
	bot["vview"] = {}
	bot["vveh_track"] = {}
	bot["structs"] = {}
	bot["gadgets"] = []
	bot["nests"] = []   # M19 P4: stale nest mirror — the next match rebuilds it from EMPLACEMENT_LIST
	bot["grenade_events"] = []
	bot["self_state"] = {}
	bot["last_seq"] = 0
	bot["server_tick"] = 0
	bot["in_vehicle"] = 0
	bot["reviving_id"] = 0
	bot["repairing"] = false
	bot["give_target"] = 0
	bot["builds_made"] = 0
	bot["reload_until"] = 0
	bot["burst_start"] = -1
	# M15: stale window/override — the next spawn's position has nothing to do with the last one.
	bot["slope_window_tick"] = -1
	bot["slope_override_until"] = -1
	(bot["ai"] as AiDriver).reset()
	net.start_client(_server_ip, _port)
	print("[bots] bot %d reconnecting..." % int(bot["index"]))

func _physics_process(delta: float) -> void:
	var frame_us := 0.0
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]:
			var wait: int = int(bot.get("reconnect_in", 0))
			if wait > 0:
				bot["reconnect_in"] = wait - 1
				if wait == 1:
					_reconnect(bot)
			continue
		bot["tick"] += 1
		var t0 := Time.get_ticks_usec()
		_drive(bot, delta)
		frame_us += float(Time.get_ticks_usec() - t0)
	_perf_us += frame_us
	_perf_frames += 1
	if _perf_frames >= 30:
		print("[bot-perf] bots=%d ai_us_mean=%.1f" % [_bots.size(), _perf_us / float(_perf_frames)])
		_perf_us = 0.0
		_perf_frames = 0

func _drive(bot: Dictionary, delta: float) -> void:
	var view: Dictionary = bot["view"]
	var me: EntityState = view.get(bot["id"])
	var buttons := 0
	var move_x := 0.0
	var move_y := 0.0

	if me == null or not me.alive:
		# Reset per-life gadget flags so the bot re-deploys on its next spawn. Over a full match this
		# yields many claymore/C4/RPG uses per bot instead of one-per-process-life, which is what the
		# fleet gate counters need (esp. mines: a single early claymore rarely catches a point-blank
		# enemy, but one placed fresh each life — facing the current enemy — reliably trips).
		bot["repairing"] = false
		bot["c4_placed"] = false
		bot["c4_detonated"] = false
		bot["mine_placed"] = false
		bot["struct_repairing"] = false   # server drops the latch on death (step_repairs); mirror it
		bot["stim_last_tick"] = -100000   # M19 P2b Task 7: fresh life = fresh 3-charge stim pool
		bot["lmg_notarget_since"] = -1    # M19 P4: server drops the seat on death; re-arm the dismount timer
		bot["in_vehicle"] = 0
		bot["fire_mode_set"] = false
		bot["has_build"] = false   # shovel-driller: drop any stale build-commit cell from the past life
		bot["fob_drill_start"] = -1   # M12-P3: re-evaluate the FOB drill fresh on the next spawn
		bot["cur_swap_slot"] = 0   # server resets active_slot to 0 on (re)spawn; mirror it
		bot["give_target"] = 0   # server clears the give latch on death; mirror it
		bot["reviving_id"] = 0   # M7.5-P3: server drops the revive on reviver death; mirror it
		bot["reload_until"] = 0  # a stale mid-burst clock made the first engagement of the new life
		bot["burst_start"] = -1  # open with a ~2.8s reload of an already-full magazine
		bot["slope_window_tick"] = -1   # M15: the next spawn point has nothing to do with the last one
		bot["slope_override_until"] = -1
		(bot["ai"] as AiDriver).reset()   # re-arm reaction gate, drop stale tracks/behaviour latch
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# DBNO: a downed bot holds still and waits for a revive OR bleeds out (halving bleedout). But if
	# no friendly is near enough to plausibly revive it, it GIVES UP immediately rather than lying
	# there for the whole bleed-out — no medic is coming (speeds up testing; ratified 2026-07-03).
	if me.is_downed:
		if not _reviver_near(view, int(bot["id"]), int(me.team), me.pos):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_CONTROL,
				Protocol.encode_give_up(), ENetPacketPeer.FLAG_RELIABLE)
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# M19 P4 Task 14: a bot MANNING an LMG nest (SELF_STATE mounted_nest != 0) is seat-locked
	# server-side — movement input is ignored, so handle it early like the CREW block below and never
	# entangle the normal move/combat/exerciser pipeline. drive_mounted_nest aims at the nearest enemy,
	# holds fire while one is within the arc, and dismounts once the fight is over. self_state is the
	# authoritative seat signal (the server clears mounted_nest on eject/death), never latched locally.
	if int((bot.get("self_state", {}) as Dictionary).get("mounted_nest", 0)) != 0:
		_ex.drive_mounted_nest(bot, me)
		return

	var role: int = BotRolesRef.of(int(bot["index"]))
	var is_crew := role == BotRolesRef.CREW
	if is_crew:
		# AUTHORITATIVE seating: derive from the replicated seat arrays every tick instead of
		# latching on the VA_ENTER *send*. The server rejects boards of wrecks / raced seats /
		# out-of-range requests — a bot that latched a phantom seat spent the rest of its life
		# sending steer/throttle as pawn movement without ever firing.
		var seated_vid := 0
		for svid in bot["vview"]:
			var sv: VehicleState = bot["vview"][svid]
			if int(bot["id"]) in sv.seats:
				seated_vid = int(svid)
				break
		if seated_vid != 0 and int(bot["in_vehicle"]) == 0:
			bot["boarded_origin"] = (bot["vview"][seated_vid] as VehicleState).pos
		elif seated_vid == 0 and int(bot["in_vehicle"]) != 0 and bool(bot["repairing"]):
			# Ejected/destroyed since last tick: drop the repair latch with the seat.
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
			bot["repairing"] = false
		bot["in_vehicle"] = seated_vid
		if seated_vid != 0:
			var v: VehicleState = bot["vview"][seated_vid]
			# Crew engineer keeps the ridden transport patched once it has taken fire.
			if int(v.hp) < VEHICLE_FULL_HP and not bool(bot["repairing"]):
				(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
					Protocol.encode_gadget_action(Protocol.GA_REPAIR_START, Vector3.ZERO, Vector3.ZERO, 0), 0)
				bot["repairing"] = true
			elif int(v.hp) >= VEHICLE_FULL_HP and bool(bot["repairing"]):
				(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
					Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
				bot["repairing"] = false
			# Drive the transport toward the nearest visible enemy (into the firefight),
			# falling back to the enemy spawn until contact. Staying mobile in combat is fine —
			# no loiter hold, so the vehicle keeps pressing into the action where blast fire is.
			var push := _hunt_pos(me, int(bot["id"]), view)
			var cmd := AiVehicleCrew.drive_toward(v.heading, me.pos, push)
			_send(bot, float(cmd["move_x"]), float(cmd["move_y"]), float(cmd["yaw"]), 0.0, 0)
			return
		else:
			var vid := AiVehicleCrew.nearest_free_vehicle(bot["vview"], me.pos, view, int(me.team))
			# Give up on a hull that keeps refusing us (e.g. an empty enemy vehicle — team isn't
			# replicated, so the picker can't rule it out): after a few rejected boards, ignore
			# that vid for a while and fight on foot instead of parking beside it.
			if vid != 0 and int((bot.get("board_blacklist", {}) as Dictionary).get(vid, -1)) > int(bot["server_tick"]):
				vid = 0
			if vid != 0:
				var v: VehicleState = bot["vview"][vid]
				var dv := me.pos.distance_to(v.pos)
				if dv <= 3.0:
					# Request the seat (retry-gated); seating is confirmed by the replicated
					# seats next snapshot — never assumed from the send.
					if int(bot["server_tick"]) - int(bot.get("last_board_tick", -100000)) >= BOARD_RETRY_TICKS:
						(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
							Protocol.encode_vehicle_action(Protocol.VA_ENTER, vid, 0), 0)
						bot["last_board_tick"] = int(bot["server_tick"])
						var tries: int = int(bot.get("board_tries", 0)) + 1
						if int(bot.get("board_try_vid", 0)) != vid:
							tries = 1   # new target hull — fresh attempt counter
						bot["board_try_vid"] = vid
						bot["board_tries"] = tries
						if tries >= BOARD_MAX_TRIES:
							var bl: Dictionary = bot.get("board_blacklist", {})
							bl[vid] = int(bot["server_tick"]) + BOARD_BLACKLIST_TICKS
							bot["board_blacklist"] = bl
							bot["board_tries"] = 0
					_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
					return
				else:
					var yaw := atan2(v.pos.x - me.pos.x, v.pos.z - me.pos.z)
					_send(bot, sin(yaw), cos(yaw), yaw, 0.0, 0)
					return
			# no vehicle in view -> fall through to normal infantry behavior

	# M12-P3: squad leaders build their squad's FOB at the per-team shared cell until it is completed.
	# Runs BEFORE the shovel-driller / combat dispatch (a leader that is also a driller does the FOB
	# drill instead — fine; the FOB drill also shovels). The large shovel-drillers converge on the same
	# cell and shovel it too, so leader + drillers exceed the FOB's min_builders=2 and it completes.
	if me != null and me.alive and not me.is_downed and _ex.fob_drill_active(bot, me):
		_ex.drive_fob_leader(bot, me)
		return

	# --- Shovel-driller logic: the BotRoles.SHOVEL cohort runs a deterministic build/shovel drill
	# so the fleet gate sees built_small/built_large/bsolo/dismantled/repaired. Like the climb
	# driller it OVERRIDES movement+combat and fully self-sends, so it never trips the normal
	# _maybe_build side-wall.
	if role == BotRolesRef.SHOVEL:
		_ex.drive_shovel_driller(bot, me)
		return

	var target: EntityState = null
	var best := INF
	for id in view:
		if id == bot["id"]: continue
		var e: EntityState = view[id]
		# Skip teammates, the dead, and DOWNED enemies (immune to weapon damage — shooting them just
		# wastes fire and lets an alive reviver standing right over them go untargeted). A reviving
		# enemy is alive + not downed, so it stays a valid (priority-by-distance) target.
		if not e.alive or e.is_downed or e.team == me.team: continue
		var dist := me.pos.distance_to(e.pos)
		if dist < best:
			best = dist; target = e

	var obj := _objective_pos(me)

	# --- Driller logic: the BotRoles.CLIMB cohort cycles the ladder+sandbag drill to guarantee the
	# fleet gate sees climbs>=1 and vaults>=1 every match. Drillers override movement but keep combat buttons.
	var is_driller := role == BotRolesRef.CLIMB
	var drill_geom_valid := false
	var _drill_ladder: Dictionary = {}
	var _drill_sandbag := Vector3.ZERO
	if is_driller and _map != null and not _map.ladders.is_empty():
		# Pick the NEAREST ladder + nearest sandbag so a driller drills its own base-side station
		# (short, survivable trek) rather than a far obstacle it would die before reaching.
		var best_ld := INF
		for l in _map.ladders:
			var lb: Vector3 = l["bottom"]
			var dl := Vector2(lb.x - me.pos.x, lb.z - me.pos.z).length()
			if dl < best_ld:
				best_ld = dl; _drill_ladder = l
		var best_sb := INF
		for pb in _map.prebuilt:
			if String(pb["type"]) != "sandbag":
				continue
			var sbw := BuildGrid.world_of(pb["cell"] as Vector3i)
			var ds := Vector2(sbw.x - me.pos.x, sbw.z - me.pos.z).length()
			if ds < best_sb:
				best_sb = ds; _drill_sandbag = sbw; drill_geom_valid = true
		drill_geom_valid = drill_geom_valid and not _drill_ladder.is_empty()

	if is_driller and drill_geom_valid:
		# Driller exerciser (M4.5-P3 climbs/vaults gate): drill the ladder+sandbag course. No combat.
		var phase: int = int(bot.get("drill_phase", AiDrill.DRILL_CLIMB))
		var dr := AiDrill.drill_step(phase, me.pos, _drill_ladder, _drill_sandbag)
		var drill_target: Vector3 = dr["move_to"]
		var flat_d := Vector2(drill_target.x - me.pos.x, drill_target.z - me.pos.z)
		if flat_d.length() > 0.001: flat_d = flat_d.normalized()
		move_x = flat_d.x
		if bool(dr["force_climb"]):
			move_y = absf(flat_d.y) + 1.0
		else:
			move_y = flat_d.y
		bot["yaw"] = atan2(move_x, flat_d.y)
		_ex.update_drill_phase(bot, int(dr["next_phase"]))
	else:
		# AI brain drives normal infantry combat + movement (retires the reflex nearest-enemy logic).
		var ai: AiDriver = bot["ai"]
		# M7.5-P3 (§E): map ladders reach the march path (climb_seek) — same MapDef source
		# the climb-driller cohort already drills on.
		var map_ladders: Array = _map.ladders if _map != null else []
		ai.observe(int(bot["id"]), view, bot["vview"], bot["structs"], _match_points, int(bot["server_tick"]), obj, map_ladders,
			bot["self_state"], bot["gadgets"], bot["grenade_events"])
		var intent := ai.decide()
		# M7.5-P3: the utility brain owns revives now — latch REVIVE_ACTION when the intent
		# carries a target, unlatch when it clears/changes (the server holds the revive while
		# the latch is active and we stay in range; range/death breaks it server-side too).
		var want_rid: int = int(intent.get("revive_target_id", 0))
		var cur_rid: int = int(bot.get("reviving_id", 0))
		if want_rid != cur_rid:
			if cur_rid != 0:
				(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
					Protocol.encode_revive_action(cur_rid, false), 0)
			if want_rid != 0:
				(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
					Protocol.encode_revive_action(want_rid, true), 0)
			bot["reviving_id"] = want_rid
		move_x = float(intent["move_x"]); move_y = float(intent["move_y"])
		bot["yaw"] = float(intent["yaw"]); bot["pitch"] = float(intent["pitch"])
		var want_fire: bool = (int(intent["buttons"]) & InputCommand.BTN_FIRE) != 0
		var cb := AiCombat.combat_button(want_fire, bot["server_tick"], bot["reload_until"], bot["burst_start"])
		buttons |= int(cb[0])
		# Forward the intent's non-fire buttons (e.g. avoid_danger's BTN_SPRINT) — FIRE stays
		# under combat_button's burst/reload cadence above and is masked out here.
		buttons |= int(intent["buttons"]) & ~InputCommand.BTN_FIRE
		bot["reload_until"] = cb[1]
		bot["burst_start"] = cb[2]
		if int(intent["stance"]) == Stance.CROUCH:
			buttons |= InputCommand.BTN_CROUCH
		# M5.5-P3 sledger override: a subset of engineers steer to a nearby structure and demolish it
		# (guarantees the fleet sees sledge hits). When sledging, skip the normal throw/gadget passes.
		var sledge_mv := _ex.maybe_sledge(bot, me)
		if not sledge_mv.is_empty():
			move_x = sledge_mv[0]; move_y = sledge_mv[1]
		# Gadget gate-exercisers (frag/flash/impact/c4/mine need a nearest enemy; smoke advances).
		elif target != null:
			# Throwable variety by index so the fleet exercises every type (server shares one cooldown).
			match int(bot["index"]) % 6:
				2: _ex.maybe_throwable(bot, me, target, Grenade.FLASHBANG, "flashes_thrown")
				5: _ex.maybe_throwable(bot, me, target, Grenade.IMPACT, "impacts_thrown")
				_: _ex.maybe_grenade(bot, me, target)
			_ex.maybe_melee(bot, me, target)
			_ex.maybe_c4(bot, me, target)
			_ex.maybe_mine(bot, me, target.pos)
		else:
			_ex.maybe_smoke(bot, me, obj)

	# M15: bot-only slope-avoidance (view-only, best-effort — the server remains authoritative and
	# still clips this bot's movement via Terrain.resolve_movement exactly like a human; see
	# shared/sim/sim_loop.gd). Skipped for the CLIMB driller: its waypoints are deliberate ladder
	# geometry, not open terrain, and overriding them would break the deterministic gate drill.
	# Reactive stuck-avoidance (view-only, best-effort — server stays authoritative): a too-steep
	# slope OR a building/prop dead ahead otherwise pins the AI commanding the same blocked heading
	# forever. _update_slope_avoid detects the stall; _pick_sidestep routes it to the terrain- or
	# structure-aware escape. Skipped for the CLIMB driller (its ladder waypoints are deliberate).
	if not is_driller:
		var avoid_dir := _update_slope_avoid(bot, me, delta, move_x, move_y)
		if avoid_dir != Vector2.ZERO:
			move_x = avoid_dir.x
			move_y = avoid_dir.y

	# M16 self-bandage: a wounded (standing-bleeding) bot retreats to patch up when no enemy is a
	# CLOSE threat — no visible enemy, or the nearest one is beyond BANDAGE_SAFE_DIST (a distant
	# threat won't stop a human from bandaging behind cover either). It then holds still + bandages
	# rather than building/throwing/firing, any of which the server treats as a channel interrupt.
	# Fair-play: reads only its OWN SELF_STATE.bleeding, exactly like a human self-bandaging.
	var ss_bandage = bot.get("self_state")
	var enemy_close: bool = target != null and me.pos.distance_to(target.pos) <= BANDAGE_SAFE_DIST
	var want_bandage: bool = ss_bandage != null and bool(ss_bandage.get("bleeding", false)) \
		and not enemy_close and not me.is_downed
	if want_bandage != bool(bot.get("bandaging", false)):
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_bandage_action(int(bot["id"]), want_bandage), 0)
		bot["bandaging"] = want_bandage
	if want_bandage:
		# Stand still, no sprint/fire, for the channel duration; the server completes the bandage.
		_send(bot, 0.0, 0.0, bot["yaw"], bot["pitch"], buttons & ~InputCommand.BTN_SPRINT & ~InputCommand.BTN_FIRE)
		return

	# Build cover only while stationary (holding a point or firing) — so the bot drops a wall
	# toward the contested objective without walking into its own piece, and the cover lands in
	# the combat zone where shots cross it. (Marching bots move, so this won't fire mid-route.)
	if move_x == 0.0 and move_y == 0.0:
		_ex.maybe_build(bot, me)
		_ex.maybe_mine(bot, me, obj)

	_ex.maybe_rpg(bot, me)
	_ex.maybe_repair_structure(bot, me)   # M19 P2b Task 6: self-gates on bot_gadget == GADGET_REPAIR
	_ex.maybe_breach(bot, me, obj)        # M19 P2b Task 6: self-gates on bot_gadget == GADGET_BREACH
	_ex.maybe_stim(bot, me, target)            # M19 P2b Task 7: self-gates on bot_gadget == GADGET_STIM
	_ex.maybe_smoke_wall(bot, me, target, obj) # M19 P2b Task 7: self-gates on bot_gadget == GADGET_SMOKE_WALL
	buttons |= _ex.maybe_riot_shield(bot, me, target)  # M19 P5 Task 7: self-gates on bot_gadget == GADGET_RIOT_SHIELD
	_ex.maybe_lmg_nest(bot, me, target)        # M19 P4 Task 14: self-gates on bot_gadget == GADGET_LMG_NEST (deploy/mount; manning handled early above)
	_ex.maybe_give(bot, me, target != null)
	_maybe_deploy_bag(bot, me)
	_ex.maybe_weapon_handling(bot, me)
	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

## M7.5-P3 needs-driven bag deploy: MEDIC/SUPPORT drop a heal/ammo bag at their feet when >=2
## nearby allies are hurt (BAG_DEPLOY_NEEDY within BAG_NEEDY_RANGE below BAG_NEEDY_HP), cooldown-
## gated by AiSupport. Complements maybe_give's one-shot throw (its GIVE latching is untouched).
func _maybe_deploy_bag(bot: Dictionary, me: EntityState) -> void:
	var cls: int = int(bot["class"])
	if cls != Loadout.MEDIC and cls != Loadout.SUPPORT:
		return   # cheap gate before the needy scan (should_deploy_bag re-checks class anyway)
	var needy := 0
	var view: Dictionary = bot["view"]
	for id in view:
		if int(id) == int(bot["id"]):
			continue
		var e: EntityState = view[id]
		if not e.alive or e.is_downed or e.team != me.team or int(e.health) >= BAG_NEEDY_HP:
			continue
		if me.pos.distance_to(e.pos) <= BAG_NEEDY_RANGE:
			needy += 1
	var now: int = int(bot["server_tick"])
	if not AiSupport.should_deploy_bag(cls, needy, now, int(bot.get("last_bag_tick", -100000))):
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_BAG_THROW, me.pos, Vector3.ZERO, 0), 0)
	bot["last_bag_tick"] = now

## Advance a driller's phase state. If the phase changed, reset the tick counter. If the phase
## has not changed but the tick counter exceeded DRILL_PHASE_TIMEOUT, force-advance to the next
## phase and reset — so a stuck driller (killed mid-traverse, geometry blocked) never stalls.
func _objective_pos(me: EntityState) -> Vector3:
	if _map == null or _map.points.is_empty():
		return me.pos
	var positions: Array = []
	var owners: Array = []
	for i in _map.points.size():
		positions.append(_map.points[i]["pos"])
		owners.append(int(_match_points[i]["owner"]) if i < _match_points.size() else -1)
	# Squad-hash spread over the top-k nearest capturable points (batch 6): squads fan out
	# instead of stacking on the single nearest point, with a bias toward enemy-owned ground.
	# Backfield still gets captured (nearest points rank first) so ticket bleed keeps working.
	# The earlier pure map-centre bias failed differently — it funnelled BOTH teams onto one
	# perpetually-contested centre point — so the spread keys off each bot's squad instead.
	var idx := AiObjective.choose_objective_spread(positions, owners, me.team, me.pos, int(me.squad))
	return positions[idx] if idx >= 0 else me.pos

## Where a crewed transport should drive: toward the nearest visible enemy (into the firefight),
## else advance on the enemy spawn until contact. Falls back to current pos if nothing is known.
func _hunt_pos(me: EntityState, self_id: int, view: Dictionary) -> Vector3:
	# EntityState carries no id (the id is the view dict key), so the caller passes bot["id"].
	var r := AiVehicleCrew.nearest_enemy_pos(view, self_id, int(me.team), me.pos)
	if bool(r["found"]):
		return r["pos"]
	if _map != null:
		return AiVehicleCrew.enemy_spawn_pos(_map.vehicle_spawns, int(me.team), me.pos)
	return me.pos

## M15: per-tick slope-avoidance bookkeeping for one bot. Tracks commanded-vs-actual horizontal
## displacement over a SLOPE_WINDOW_TICKS window; when it looks clipped by a too-steep hill
## (is_slope_stuck), latches a sidestep heading (slope_sidestep) for SLOPE_OVERRIDE_TICKS. Returns
## Vector2.ZERO when no override is active (caller keeps its own move_x/move_y this tick); otherwise
## the {move_x, move_y} pair to send instead. View-only: never touches server/sim authority — a
## miss or an over-correction here does nothing worse than a normal human bump against the same hill.
## Choose an escape heading when a march stalls: if the ground dead ahead is genuinely too steep it's
## a slope block -> the terrain-aware slope_sidestep; otherwise the bot is jammed against a building or
## prop on walkable ground -> obstacle_sidestep toward the clearer side of the nearby structure cells.
func _pick_sidestep(bot: Dictionary, me: EntityState, heading: Vector3) -> Vector3:
	if _terrain != null:
		var ahead := me.pos + heading.normalized() * (_terrain.spacing * 1.5)
		if Terrain.slope_at(_terrain, ahead.x, ahead.z) > Terrain.MAX_WALKABLE_SLOPE_DEG:
			return slope_sidestep(_terrain, me.pos, heading)
	return obstacle_sidestep(me.pos, heading, nearby_obstacle_cells(bot["structs"], me.pos))

func _update_slope_avoid(bot: Dictionary, me: EntityState, delta: float, move_x: float, move_y: float) -> Vector2:
	var tick := int(bot["tick"])
	if int(bot["slope_window_tick"]) < 0:
		bot["slope_window_tick"] = tick
		bot["slope_window_pos"] = me.pos
		bot["slope_commanded"] = 0.0
	bot["slope_commanded"] = float(bot["slope_commanded"]) + Vector2(move_x, move_y).length() * delta * SLOPE_NOMINAL_SPEED
	if tick - int(bot["slope_window_tick"]) >= SLOPE_WINDOW_TICKS:
		var wp: Vector3 = bot["slope_window_pos"]
		var actual := Vector2(me.pos.x - wp.x, me.pos.z - wp.z).length()
		var commanded: float = bot["slope_commanded"]
		if is_slope_stuck(commanded, actual):
			var heading := Vector3(move_x, 0.0, move_y)
			if heading.length() > 0.01:
				var sd := _pick_sidestep(bot, me, heading)
				bot["slope_override_dir"] = Vector2(sd.x, sd.z)
				bot["slope_override_until"] = tick + SLOPE_OVERRIDE_TICKS
		bot["slope_window_tick"] = tick
		bot["slope_window_pos"] = me.pos
		bot["slope_commanded"] = 0.0
	if tick <= int(bot["slope_override_until"]):
		return bot["slope_override_dir"] as Vector2
	return Vector2.ZERO

func _send(bot: Dictionary, mx: float, my: float, yaw: float, pitch: float, buttons: int) -> void:
	var bytes := InputCommand.encode(bot["tick"], bot["last_seq"], mx, my, yaw, pitch, buttons, bot["server_tick"])
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)

func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var w := Protocol.decode_welcome(bytes)
			bot["id"] = int(w["id"])
			bot["class"] = int(w["class"])
			(bot["ai"] as AiDriver).bot_class = int(w["class"])   # MEDIC widens revive reach (M7.5-P3)
			bot["connected"] = true
			# Map-rotation reconnect: the server may now be running a DIFFERENT map — adopt it like
			# the rendered client does, or objectives/ladders/vehicle spawns point at the old world.
			var srv_map := String(w.get("map", ""))
			if srv_map != "" and srv_map != _map_path.get_file().get_basename():
				var new_path := "res://maps/%s.json" % srv_map
				var nm := MapDef.load_file(new_path)
				if nm != null:
					_map_path = new_path
					_map = nm
					_terrain = Terrain.load_for_map(_map, "res://maps", Callable())   # M15: rebuild for the new map
					_match_points = []   # stale point owners; refreshed by the next MATCH_STATE
					print("[bots] adopting server map: %s" % srv_map)
			print("[bots] bot %d connected (id %d class %d) — %d/%d" % [bot["index"], bot["id"], bot["class"], _connected_count(), _bot_count])
		Protocol.Msg.SNAPSHOT:
			var hdr := Snapshot.decode_apply(bytes, bot["view"], bot["vview"])
			bot["last_seq"] = maxi(bot["last_seq"], int(hdr["seq"]))
			bot["server_tick"] = int(hdr["server_tick"])
		Protocol.Msg.MATCH_STATE:
			_match_points = Protocol.decode_match_state(bytes)["points"]
		Protocol.Msg.STRUCTURE_DELTA:
			AiVehicleCrew.apply_structure_delta(bot["structs"], Protocol.decode_structure_delta(bytes))
			_note_sync(bot)
		Protocol.Msg.STRUCTURE_BASELINE:
			for rec in Protocol.decode_structure_baseline(bytes)["records"]:
				bot["structs"][rec["id"]] = rec
			_note_sync(bot)
		Protocol.Msg.SMOKE_DEPLOYED:
			pass   # no bot-side effect until M7 LOS culling; received reliably, nothing to do
		Protocol.Msg.SELF_STATE:
			# M7.5-P3: own ammo/bandage/being-revived state feeds the support behaviours
			# (Perception reads mag/weapon; the downed branch reads the bandage fields).
			bot["self_state"] = Protocol.decode_self_state(bytes)
		Protocol.Msg.GADGET_LIST:
			# Authoritative deployed-gadget list (mines/bags/C4) — replace wholesale, exactly
			# like the client's consumption pattern (no per-removal bookkeeping needed).
			bot["gadgets"] = Protocol.decode_gadget_list(bytes)
		Protocol.Msg.EMPLACEMENT_LIST:
			# M19 P4: authoritative deployed LMG-nest list — replace wholesale (self-healing render
			# list), same pattern as GADGET_LIST. Feeds maybe_lmg_nest (mount/redeploy decisions).
			bot["nests"] = Protocol.decode_emplacement_list(bytes)
		Protocol.Msg.GRENADE_FX:
			# A remote pawn threw a grenade: stamp a flat GRENADE_LANDING_EST-ahead landing
			# estimate into a small ring; AiSupport.danger_zones expires entries by tick.
			# FRAG only — the server also broadcasts SMOKE arcs (harmless; own team smokes
			# objectives constantly, and fleeing those would scatter every push).
			var g := Protocol.decode_grenade_fx(bytes)
			if int(g["kind"]) == Grenade.FRAG:
				# Friendly frags are FF-off (harmless) — fleeing them scattered whole squads
				# (avoid_danger outweighs everything) and aborted in-progress revives for nothing.
				# The FX packet carries the thrower's team; only ENEMY frags become danger zones.
				var self_es: EntityState = (bot.get("view", {}) as Dictionary).get(int(bot.get("id", 0)))
				if self_es == null or int(g.get("team", -1)) != int(self_es.team):
					var events: Array = bot["grenade_events"]
					events.append({"pos": (g["origin"] as Vector3) + (g["dir"] as Vector3).normalized() * GRENADE_LANDING_EST,
						"tick": int(bot["server_tick"])})
					if events.size() > MAX_GRENADE_EVENTS:
						events.pop_front()
		_:
			pass

func _note_sync(bot: Dictionary) -> void:
	if not _synced_logged and not bot["structs"].is_empty():
		_synced_logged = true
		print("[bots] structures synced: bot %d sees %d piece(s)" % [bot["id"], bot["structs"].size()])

func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]: n += 1
	return n
