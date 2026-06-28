class_name BotDriver
extends Node
## Headless bot fleet. Each bot is a real client that decodes its interest view and
## fights the nearest enemy. Many bots per process (load + playtest). See M2 spec.

const Protocol := preload("res://shared/net/protocol.gd")
const MAP_PATH := "res://maps/conquest_proving_grounds.json"   # default; override with --map=<name>
const BUILD_COOLDOWN_TICKS := 150   # match server StructureStore.BUILD_COOLDOWN_TICKS (5s)
const BUILD_DIST := 3.0             # how far ahead (m) to drop cover; within server BUILD_RANGE
const MAX_BOT_BUILDS := 3           # per-bot lifetime BUILD_REQUEST cap. Re-enabled (was 0) so the
                                    # M12-P2 shovel-drillers (index % 8 == 4) can PLACE build sites and
                                    # the fleet gate sees built_small/built_large/bsolo/dismantled/repaired.
                                    # Normal bots only drop a side-wall while stationary (original gate
                                    # behaviour); 3 is a small cap so it does not clutter combat.
const PIECES_PATH := "res://pieces/pieces.json"   # match server PIECES_PATH (shovel-drill type lookup)
const WALL_TYPE := 1                # small piece (min_builders 1) shovel-drillers build solo
const SHOVEL_APPROACH := BuildSite.SHOVEL_RANGE * 0.8   # stop+shovel once this close to the site centre
const BUILD_COMMIT_TICKS := 90     # ticks a driller stays on a just-placed cell awaiting its site delta
const SHOVEL_SEEK_RANGE := 28.0    # m: build-capped drillers roam to a structure within this to repair/dismantle
const WALL_OFFSET := 3.5           # m ahead a small driller drops its wall (> CELL_SIZE so it never hits self-cell)
const GRENADE_COOLDOWN_TICKS := 300   # match server GRENADE_COOLDOWN_TICKS (10s, shared frag/smoke)
const MAX_BOT_GRENADES := 1           # per-bot lifetime FRAG cap (convergence/over-destruction knob)
const MAX_BOT_SMOKES := 1             # per-bot lifetime SMOKE cap (exercises the smoke path)
const MAX_BOT_SPECIAL_THROWS := 3     # per-bot lifetime FLASHBANG/IMPACT cap (M5.5-P3 gate exerciser)
const MELEE_COOLDOWN_TICKS := 24      # match server MELEE_COOLDOWN_TICKS (~0.8s)
const SLEDGE_SEEK_RANGE := 10.0       # m — engineer sledgers steer to a structure within this range
const MAX_VEHICLE_BOTS := 6   # crew bots per process; minority so the win-convergence holds
const VEHICLE_FULL_HP := 600       # transport max (v1 single vehicle type); used to detect a damaged ridden vehicle
const VEHICLE_RPG_RANGE := 120.0   # fire an RPG at an enemy vehicle within this many metres
const RPG_FIRE_COOLDOWN := 120     # ticks between RPG fire attempts (matches server cooldown_ticks)
const ROCKET_SPEED := 150.0  # keep in sync with data/gadgets.json rpg.rocket_speed (bot lead math)
const ROCKET_GRAVITY := 20.0  # matches Grenade.GRAVITY; bots aim higher by 1/2 g t^2 to counter rocket drop

var _map: MapDef
var _map_path: String = MAP_PATH   # --map=<name> overrides (must match server + client)
var _match_points: Array = []   # array of {owner, attacker, cap}, index == map point index
var _synced_logged := false   # logs once when any bot first sees a structure (gate signal)

var _server_ip := "127.0.0.1"
var _port := 27015
var _bot_count := 1
var _bots: Array[Dictionary] = []
var _global_seed: int = 12345

var _perf_us: float = 0.0
var _perf_frames: int = 0

var _heavy_type: int = 22   # heavy_barricade catalog index (large, min_builders 2); resolved in _ready

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_bot_count = maxi(1, int(args.get("bot-count", _bot_count)))
	_global_seed = int(args.get("seed", _global_seed))
	if args.has("map"):
		_map_path = "res://maps/%s.json" % String(args["map"])

func _ready() -> void:
	_map = MapDef.load_file(_map_path)
	if _map == null:
		push_error("[bots] failed to load map %s" % _map_path)
	# Resolve the large-cooperation piece index once so the shovel-drill stays correct if the catalog
	# re-orders (falls back to the known last index 22 if the lookup fails).
	var cat := PieceCatalog.load_file(PIECES_PATH)
	if cat != null:
		var hi := cat.index_of("heavy_barricade")
		if hi >= 0:
			_heavy_type = hi
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
		"last_grenade_tick": -100000, "nades_thrown": 0, "smokes_thrown": 0,
		"flashes_thrown": 0, "impacts_thrown": 0, "last_melee_tick": -100000,
		"class": 0, "rpg_last_tick": -100000, "c4_placed": false, "c4_detonated": false,
		"mine_placed": false, "gave_until": 0,
		"vview": {}, "in_vehicle": 0, "boarded_origin": Vector3.ZERO, "repairing": false,
		"vveh_track": {},
		"ai": AiDriver.new(_global_seed, index, "regular"),
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void: _on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)

func _physics_process(delta: float) -> void:
	var frame_us := 0.0
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]: continue
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
		bot["in_vehicle"] = 0
		bot["fire_mode_set"] = false
		bot["has_build"] = false   # shovel-driller: drop any stale build-commit cell from the past life
		bot["cur_swap_slot"] = 0   # server resets active_slot to 0 on (re)spawn; mirror it
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# DBNO: downed pawns are immune to weapon damage, so a downed bot holds still and waits to be
	# revived. It does NOT self-bandage — halting the bleed under the immune model would make it
	# immortal and stall the match; instead it bleeds out if no teammate reaches it in time.
	if me.is_downed:
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# Revive a downed teammate if one is close enough — but ONLY the single nearest alive teammate
	# goes for the revive; everyone else keeps fighting (no whole-squad swarm that stalls combat).
	var rid := _nearest_downed_teammate(bot, me)
	if rid != 0 and _is_closest_reviver(bot, me, rid):
		var tpos: Vector3 = (bot["view"][rid] as EntityState).pos
		var to := tpos - me.pos
		if to.length() <= Revive.REVIVE_RANGE:
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_revive_action(rid, true), 0)
			# Hold still, face the downed mate, and crouch over them (BattleBit medic posture —
			# smaller silhouette / steadier hold) for the duration of the revive.
			_send(bot, 0.0, 0.0, atan2(to.x, to.z), 0.0, InputCommand.BTN_CROUCH)
			return
		else:
			var myaw := atan2(to.x, to.z)
			_send(bot, sin(myaw), cos(myaw), myaw, 0.0, 0)
			return

	var is_crew := int(bot["index"]) % 5 == 1 and int(bot["index"]) < MAX_VEHICLE_BOTS * 5
	if is_crew:
		if int(bot["in_vehicle"]) != 0:
			var v: VehicleState = bot["vview"].get(bot["in_vehicle"])
			if v == null:   # vehicle destroyed / out of view -> consider self ejected
				if bool(bot["repairing"]):
					(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
						Protocol.encode_gadget_action(Protocol.GA_REPAIR_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
					bot["repairing"] = false
				bot["in_vehicle"] = 0
			else:
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
			var vid := AiVehicleCrew.nearest_free_vehicle(bot["vview"], me.pos)
			if vid != 0:
				var v: VehicleState = bot["vview"][vid]
				var d := me.pos.distance_to(v.pos)
				if d <= 3.0:
					(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
						Protocol.encode_vehicle_action(Protocol.VA_ENTER, vid, 0), 0)
					bot["in_vehicle"] = vid
					bot["boarded_origin"] = v.pos
					_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
					return
				else:
					var yaw := atan2(v.pos.x - me.pos.x, v.pos.z - me.pos.z)
					_send(bot, sin(yaw), cos(yaw), yaw, 0.0, 0)
					return
			# no vehicle in view -> fall through to normal infantry behavior

	# --- Shovel-driller logic: ~1 in 8 bots (index % 8 == 4, DISJOINT from the climb driller at
	# %8==0) run a deterministic build/shovel drill so the fleet gate sees built_small/built_large/
	# bsolo/dismantled/repaired. Like the climb driller it OVERRIDES movement+combat (it does NOT also
	# run the climb drill) and fully self-sends, so it never trips the normal _maybe_build side-wall.
	if int(bot["index"]) % 8 == 4:
		_drive_shovel_driller(bot, me)
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

	# --- Driller logic: ~1 in 8 bots cycle the ladder+sandbag drill to guarantee the fleet gate
	# sees climbs>=1 and vaults>=1 every match. Drillers override movement but keep combat buttons.
	var is_driller := int(bot["index"]) % 8 == 0
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
		_update_drill_phase(bot, int(dr["next_phase"]))
	else:
		# AI brain drives normal infantry combat + movement (retires the reflex nearest-enemy logic).
		var ai: AiDriver = bot["ai"]
		ai.observe(int(bot["id"]), view, bot["vview"], bot["structs"], _match_points, int(bot["server_tick"]), obj)
		var intent := ai.decide()
		move_x = float(intent["move_x"]); move_y = float(intent["move_y"])
		bot["yaw"] = float(intent["yaw"]); bot["pitch"] = float(intent["pitch"])
		var want_fire: bool = (int(intent["buttons"]) & InputCommand.BTN_FIRE) != 0
		var cb := AiCombat.combat_button(want_fire, bot["server_tick"], bot["reload_until"], bot["burst_start"])
		buttons |= int(cb[0])
		bot["reload_until"] = cb[1]
		bot["burst_start"] = cb[2]
		if int(intent["stance"]) == Stance.CROUCH:
			buttons |= InputCommand.BTN_CROUCH
		# M5.5-P3 sledger override: a subset of engineers steer to a nearby structure and demolish it
		# (guarantees the fleet sees sledge hits). When sledging, skip the normal throw/gadget passes.
		var sledge_mv := _maybe_sledge(bot, me)
		if not sledge_mv.is_empty():
			move_x = sledge_mv[0]; move_y = sledge_mv[1]
		# Gadget gate-exercisers (frag/flash/impact/c4/mine need a nearest enemy; smoke advances).
		elif target != null:
			# Throwable variety by index so the fleet exercises every type (server shares one cooldown).
			match int(bot["index"]) % 6:
				2: _maybe_throwable(bot, me, target, Grenade.FLASHBANG, "flashes_thrown")
				5: _maybe_throwable(bot, me, target, Grenade.IMPACT, "impacts_thrown")
				_: _maybe_grenade(bot, me, target)
			_maybe_melee(bot, me, target)
			_maybe_c4(bot, me, target)
			_maybe_mine(bot, me, target.pos)
		else:
			_maybe_smoke(bot, me, obj)

	# Build cover only while stationary (holding a point or firing) — so the bot drops a wall
	# toward the contested objective without walking into its own piece, and the cover lands in
	# the combat zone where shots cross it. (Marching bots move, so this won't fire mid-route.)
	if move_x == 0.0 and move_y == 0.0:
		_maybe_build(bot, me)
		_maybe_mine(bot, me, obj)

	_maybe_rpg(bot, me)
	_maybe_give(bot, me)
	_maybe_weapon_handling(bot, me)
	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

## Advance a driller's phase state. If the phase changed, reset the tick counter. If the phase
## has not changed but the tick counter exceeded DRILL_PHASE_TIMEOUT, force-advance to the next
## phase and reset — so a stuck driller (killed mid-traverse, geometry blocked) never stalls.
func _update_drill_phase(bot: Dictionary, next_phase: int) -> void:
	var cur_phase: int = int(bot.get("drill_phase", AiDrill.DRILL_CLIMB))
	var ticks: int = int(bot.get("drill_phase_ticks", 0))
	if next_phase != cur_phase:
		# Phase transition from drill_step logic.
		bot["drill_phase"] = next_phase
		bot["drill_phase_ticks"] = 0
	else:
		ticks += 1
		if ticks >= AiDrill.DRILL_PHASE_TIMEOUT:
			# Stuck: force the other phase and reset.
			bot["drill_phase"] = AiDrill.DRILL_VAULT if cur_phase == AiDrill.DRILL_CLIMB else AiDrill.DRILL_CLIMB
			bot["drill_phase_ticks"] = 0
		else:
			bot["drill_phase_ticks"] = ticks

## True if THIS bot is the nearest alive teammate (in its view) to the downed mate `rid` — so only
## one reviver commits while the rest keep fighting. Ties broken by id for a stable single winner.
func _is_closest_reviver(bot: Dictionary, me: EntityState, rid: int) -> bool:
	var view: Dictionary = bot["view"]
	if not view.has(rid):
		return false
	var dpos: Vector3 = (view[rid] as EntityState).pos
	var my_d: float = me.pos.distance_to(dpos)
	if my_d <= Revive.REVIVE_RANGE:
		return true   # already in revive range -> always commit, never strand a downed mate
	var my_id: int = int(bot["id"])
	for id in view:
		if int(id) == my_id or int(id) == rid:
			continue
		var e: EntityState = view[id]
		if not e.alive or e.is_downed or e.team != me.team:
			continue
		var d: float = e.pos.distance_to(dpos)
		if d < my_d - 0.01 or (absf(d - my_d) <= 0.01 and int(id) < my_id):
			return false   # a closer (or tie-broken) teammate will take this revive
	return true

func _nearest_downed_teammate(bot: Dictionary, me: EntityState) -> int:
	if me == null:
		return 0
	var best := 0
	var best_d := INF
	var view: Dictionary = bot["view"]
	for id in view:
		var e: EntityState = view[id]
		if not e.is_downed:
			continue
		if e.team != me.team:
			continue
		var d: float = me.pos.distance_to(e.pos)
		if d < best_d and d < 20.0:
			best_d = d
			best = id
	return best

func _maybe_build(bot: Dictionary, me: EntityState) -> void:
	if int(bot["builds_made"]) >= MAX_BOT_BUILDS:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_build_tick"]) < BUILD_COOLDOWN_TICKS:
		return
	# Drop cover to the bot's SIDE (perpendicular to its facing), one step away. The caller only
	# invokes this while stationary. A full-height WALL is used so it blocks standing eye-height
	# shots (a half-height sandbag sits below the ~1.6 m sight line and never blocks combat).
	# Placing it to the side rather than down the firing line means the bot keeps engaging
	# forward (so attrition still converges the match) while the wall blocks flanking crossfire.
	var dir := Vector2(cos(me.yaw), -sin(me.yaw))   # right-hand perpendicular to facing
	var target := me.pos + Vector3(dir.x, 0.0, dir.y) * BUILD_DIST
	var cell := BuildGrid.cell_of(Vector3(target.x, 0.0, target.z))
	var yaw_step := int(round(me.yaw / (TAU / float(BuildGrid.YAW_STEPS)))) % BuildGrid.YAW_STEPS
	if yaw_step < 0: yaw_step += BuildGrid.YAW_STEPS
	var bytes := Protocol.encode_build_request(1, cell, yaw_step)   # type 1 = wall (full height)
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)
	bot["last_build_tick"] = st
	bot["builds_made"] = int(bot["builds_made"]) + 1

## M12-P2 shovel-driller (index % 8 == 4): place build sites + hold BTN_SHOVEL to build them, and
## shovel finished structures the server then auto-repairs (friendly+holed) or dismantles (enemy).
## Self-contained: computes move + buttons and _sends, so it never runs combat or the side-wall build.
## A LARGE-cooperation sub-subset (index % 16 == 4) converges on ONE shared per-team heavy_barricade
## cell so >=2 of them build it together (built_large); a lone one there trips bsolo while it waits.
func _drive_shovel_driller(bot: Dictionary, me: EntityState) -> void:
	var structs: Dictionary = bot["structs"]
	var is_large: bool = int(bot["index"]) % 16 == 4

	# 1. Pick a work target cell (Vector3i). Build sites are PRIMARY (so the structure-dense map's
	#    finished pieces never starve the build path); shovelling a nearby finished structure (repair/
	#    dismantle) is the fallback once a driller has spent its build cap.
	var target_cell := Vector3i.ZERO
	var have_target := false

	if is_large and _map != null and not _map.base_for(int(me.team)).is_empty():
		# Large-cooperation: every large driller on the team locks the SAME shared cell so >=2 converge.
		target_cell = _shared_large_cell(int(me.team))
		have_target = true
		if not _cell_known(structs, target_cell):
			if me.pos.distance_to(BuildGrid.world_of(target_cell)) <= StructureStore.BUILD_RANGE - 0.5:
				_place_site(bot, me, _heavy_type, target_cell)
	else:
		# (P1) Commit to a sticky own build cell until the site finishes (or proves rejected/decayed).
		#      This is what stops the structure-dense map's branch-(P3) shovel from diverting a driller
		#      off its half-built wall every tick.
		if bool(bot.get("has_build", false)):
			var bc: Vector3i = bot["build_cell"]
			var rec := _struct_at(structs, bc)
			if not rec.is_empty():
				if int(rec.get("under_construction", 0)) == 1:
					target_cell = bc; have_target = true        # still building -> stay on it
				else:
					bot["has_build"] = false                    # completed -> release
			elif int(bot["server_tick"]) - int(bot.get("build_set_tick", 0)) < BUILD_COMMIT_TICKS:
				target_cell = bc; have_target = true            # placed; site delta in flight -> hold
			else:
				bot["has_build"] = false                        # never appeared (rejected) -> retry
		# (P2) Place a fresh wall ahead and commit to it (until the per-life build cap is spent).
		if not have_target:
			var cell := _wall_cell(me)
			if _place_site(bot, me, WALL_TYPE, cell):
				bot["has_build"] = true
				bot["build_cell"] = cell
				bot["build_set_tick"] = int(bot["server_tick"])
				target_cell = cell; have_target = true
		# (P3) Fallback (build-capped): seek the nearest known structure in range and shovel it — the
		#      server repairs it (friendly + holed) or dismantles it (enemy). Wide range so a driller
		#      that has finished building roams to a real structure instead of idling.
		if not have_target:
			var best_d := SHOVEL_SEEK_RANGE
			for sid in structs:
				var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
				var d := me.pos.distance_to(wp)
				if d < best_d:
					best_d = d; target_cell = structs[sid]["cell"]; have_target = true

	if not have_target:
		# Nothing to work yet (e.g. build on cooldown, no structure in seek range) — hold + face forward.
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# 2. Steer to the target and shovel. Face the centre (atan2(dir.x, dir.z)); stop + hold BTN_SHOVEL
	#    once within range so the server accrues progress / repairs / dismantles.
	var center := BuildGrid.world_of(target_cell)
	var to := center - me.pos
	var flat := Vector2(to.x, to.z)
	var dist := flat.length()
	var move_x := 0.0
	var move_y := 0.0
	var buttons := 0
	if dist > 0.001:
		bot["yaw"] = atan2(to.x, to.z)
	if dist <= SHOVEL_APPROACH:
		pass   # in range: hold position
	else:
		var n := flat / dist
		move_x = n.x; move_y = n.y
	if dist <= BuildSite.SHOVEL_RANGE:
		buttons |= InputCommand.BTN_SHOVEL   # server resolves build vs repair vs dismantle
	_send(bot, move_x, move_y, bot["yaw"], 0.0, buttons)

## Deterministic shared heavy_barricade cell for a team: 4 m in front of the team base toward the map
## centre (origin), snapped to a build cell. Every large driller on the team computes the same cell so
## they converge on one site. Reachable (near spawn) and clear of the base itself.
func _shared_large_cell(team: int) -> Vector3i:
	var bpos: Vector3 = _map.base_for(team)["pos"]
	var toward := Vector3(-bpos.x, 0.0, -bpos.z)
	if toward.length() < 0.01:
		toward = Vector3(0.0, 0.0, 1.0)
	var p := bpos + toward.normalized() * 4.0
	return BuildGrid.cell_of(Vector3(p.x, 0.0, p.z))

## Cell a small driller drops its wall in: WALL_OFFSET ahead of its facing, snapped to a build cell.
## The offset exceeds CELL_SIZE so the cell is never the player's own cell (server rejects self-cell);
## if rounding still lands on it, push one cell further along the facing.
func _wall_cell(me: EntityState) -> Vector3i:
	var fwd := Vector3(sin(me.yaw), 0.0, cos(me.yaw))
	var cell := BuildGrid.cell_of(me.pos + fwd * WALL_OFFSET)
	if cell == BuildGrid.cell_of(Vector3(me.pos.x, 0.0, me.pos.z)):
		cell = BuildGrid.cell_of(me.pos + fwd * (WALL_OFFSET + BuildGrid.CELL_SIZE))
	return cell

## The known structure/site record at `cell` (empty Dictionary if none).
func _struct_at(structs: Dictionary, cell: Vector3i) -> Dictionary:
	for sid in structs:
		if (structs[sid]["cell"] as Vector3i) == cell:
			return structs[sid]
	return {}

## True if a known structure/site already occupies `cell` (so a driller shovels it instead of re-placing).
func _cell_known(structs: Dictionary, cell: Vector3i) -> bool:
	for sid in structs:
		if (structs[sid]["cell"] as Vector3i) == cell:
			return true
	return false

## Send a BUILD_REQUEST for `type` at `cell` if the per-bot cap + cooldown allow. Returns true if sent.
## The server independently validates range/occupancy/cooldown, so a rejected request is harmless.
func _place_site(bot: Dictionary, me: EntityState, type: int, cell: Vector3i) -> bool:
	if int(bot["builds_made"]) >= MAX_BOT_BUILDS:
		return false
	var st: int = bot["server_tick"]
	if st - int(bot["last_build_tick"]) < BUILD_COOLDOWN_TICKS:
		return false
	var yaw_step := int(round(me.yaw / (TAU / float(BuildGrid.YAW_STEPS)))) % BuildGrid.YAW_STEPS
	if yaw_step < 0: yaw_step += BuildGrid.YAW_STEPS
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_build_request(type, cell, yaw_step), 0)
	bot["last_build_tick"] = st
	bot["builds_made"] = int(bot["builds_made"]) + 1
	return true

## Throw a FRAG at an in-view enemy when a structure sits roughly on the line between us and them
## (so the blast clears cover) — shared cooldown + per-bot frag cap. Drives the blast/destruction gate.
func _maybe_grenade(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if int(bot["nades_thrown"]) >= MAX_BOT_GRENADES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS:
		return
	if not _cover_between(bot, me.pos, target.pos):
		return
	var dir := target.pos - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.FRAG), 0)
	bot["last_grenade_tick"] = st
	bot["nades_thrown"] = int(bot["nades_thrown"]) + 1

## Throw a SMOKE toward the objective while advancing (no target) — shared cooldown + per-bot smoke
## cap. No gameplay effect until M7 LOS culling; exercises the smoke replication path for the gate.
func _maybe_smoke(bot: Dictionary, me: EntityState, obj: Vector3) -> void:
	if int(bot["smokes_thrown"]) >= MAX_BOT_SMOKES:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS:
		return
	var dir := obj - me.pos
	if dir.length() < 0.001:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), Grenade.SMOKE), 0)
	bot["last_grenade_tick"] = st
	bot["smokes_thrown"] = int(bot["smokes_thrown"]) + 1

## Throw a FLASHBANG/IMPACT at a visible nearby enemy (M5.5-P3 gate exerciser). Shares the server
## throw cooldown + has a per-bot lifetime cap; aims directly at the target (flash blinds; impact
## detonates on contact).
func _maybe_throwable(bot: Dictionary, me: EntityState, target: EntityState, type: int, count_key: String) -> void:
	if int(bot.get(count_key, 0)) >= MAX_BOT_SPECIAL_THROWS:
		return
	var st: int = bot["server_tick"]
	if st - int(bot["last_grenade_tick"]) < GRENADE_COOLDOWN_TICKS:
		return
	var dir := target.pos - me.pos
	var dist := dir.length()
	if dist < 0.001 or dist > 30.0:
		return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_grenade_throw(dir.normalized(), type), 0)
	bot["last_grenade_tick"] = st
	bot[count_key] = int(bot.get(count_key, 0)) + 1

## Quick-knife when an enemy is at point-blank (M5.5-P3). Face the target so the server's
## frontal-cone selection picks it up; server cooldown-gates and resolves back-stab vs body damage.
func _maybe_melee(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if me.pos.distance_to(target.pos) > Melee.MELEE_RANGE + 0.4:
		return
	var st: int = bot["server_tick"]
	if st - int(bot.get("last_melee_tick", -100000)) < MELEE_COOLDOWN_TICKS:
		return
	var to := target.pos - me.pos
	bot["yaw"] = atan2(to.x, to.z)
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_melee(), 0)
	bot["last_melee_tick"] = st

## Engineer sledgehammer exerciser: a subset of engineers (id % 4 == 0) steer to the nearest known
## structure and melee it in reach (the server demolishes the struck cell). Returns a [mx,my]
## movement override, or [] for bots that should drive normally. Best-effort — the deterministic
## gate proves the mechanic; this guarantees the fleet exercises it on building-dense maps.
func _maybe_sledge(bot: Dictionary, me: EntityState) -> Array:
	if int(bot["class"]) != Loadout.ENGINEER or int(bot["id"]) % 4 != 0:
		return []
	var structs: Dictionary = bot["structs"]
	if structs.is_empty():
		return []
	var best_id := 0
	var best_d := SLEDGE_SEEK_RANGE
	for sid in structs:
		var wp: Vector3 = BuildGrid.world_of(structs[sid]["cell"] as Vector3i)
		var d := me.pos.distance_to(wp)
		if d < best_d:
			best_d = d; best_id = sid
	if best_id == 0:
		return []
	var to: Vector3 = BuildGrid.world_of(structs[best_id]["cell"] as Vector3i) - me.pos
	if to.length() <= Melee.MELEE_RANGE + 0.3:
		var st: int = bot["server_tick"]
		if st - int(bot.get("last_melee_tick", -100000)) >= MELEE_COOLDOWN_TICKS:
			bot["yaw"] = atan2(to.x, to.z); bot["pitch"] = 0.0
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, Protocol.encode_melee(), 0)
			bot["last_melee_tick"] = st
		return [0.0, 0.0]   # hold position while demolishing
	var f := Vector2(to.x, to.z).normalized()
	bot["yaw"] = atan2(f.x, f.y)
	return [f.x, f.y]

## Exercise fire-mode cycling and secondary weapon swap for a deterministic subset of bots.
## Fire-mode: bots where index % 5 == 0 (and not Engineer, which uses SMG that lacks BURST)
## send MODE_BURST once per bot life (on first invocation after spawn, gated by fire_mode_set).
## Swap: bots where index % 4 == 0 swap to secondary at server_tick % 600 == 120 and back at
## server_tick % 600 == 240 — guaranteed within the first ~10s of any match.
func _maybe_weapon_handling(bot: Dictionary, me: EntityState) -> void:
	# Reset per-life flag when bot is not alive (called only when alive, but fire_mode_set
	# is also reset in the dead-bot branch via the respawn reset block, mirroring other flags).
	# Fire-mode: index % 5 == 0, non-Engineer only (AR supports BURST; SMG does not).
	if int(bot["index"]) % 5 == 0 and int(bot["class"]) != Loadout.ENGINEER:
		if not bool(bot.get("fire_mode_set", false)):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_set_fire_mode(Weapon.MODE_BURST), 0)
			bot["fire_mode_set"] = true
	# Periodic secondary swap: index % 4 == 0. Transition-based (send only on a slot change) so it is
	# robust to the bot's server_tick advancing by SNAPSHOT_STRIDE (an exact `== N` tick match would be
	# skipped). Cycle: secondary for one ~4s quarter of a ~16s loop, primary otherwise.
	if int(bot["index"]) % 4 == 0:
		var cycle: int = (int(bot["server_tick"]) / 120) % 4
		var want_slot: int = 1 if cycle == 1 else 0
		if want_slot != int(bot.get("cur_swap_slot", 0)):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_swap_weapon(want_slot), 0)
			bot["cur_swap_slot"] = want_slot

## Engineer RPG is anti-vehicle first; falls back to targeting nearby structural building pieces
## (building_id != 0) near the bot's current objective when no enemy vehicle is in range.
## Estimate the vehicle target's velocity from successive snapshots and lead the aim by the
## rocket's flight time so a moving transport actually gets hit. Cooldown-gated (the server also
## enforces the real per-rocket cooldown + the 3-rocket reserve).
func _maybe_rpg(bot: Dictionary, me: EntityState) -> void:
	if bot["class"] != Loadout.ENGINEER: return
	var vveh := AiVehicleCrew.nearest_enemy_vehicle(bot["vview"], bot["view"], me.pos, int(me.team), VEHICLE_RPG_RANGE)
	if vveh != 0:
		var vv: VehicleState = bot["vview"][vveh]
		var now := int(bot["server_tick"])
		# Update the velocity estimate for this vehicle (only when its position actually advanced).
		var track: Dictionary = bot["vveh_track"]
		var prev = track.get(vveh)
		var vel := Vector3.ZERO
		if prev != null:
			vel = prev["vel"]   # persist last good estimate between snapshots
			var dt_ticks := now - int(prev["tick"])
			var moved: Vector3 = vv.pos - (prev["pos"] as Vector3)
			if dt_ticks > 0 and moved.length() > 0.01:
				vel = moved / (float(dt_ticks) * SimLoop.DT)
		if prev == null or (vv.pos - (prev["pos"] as Vector3)).length() > 0.01:
			track[vveh] = {"pos": vv.pos, "tick": now, "vel": vel}
		# Cooldown gate (do the aim/fire only when ready).
		if now - int(bot["rpg_last_tick"]) < RPG_FIRE_COOLDOWN: return
		var origin := me.pos
		var flight: float = origin.distance_to(vv.pos) / ROCKET_SPEED
		# Lead the target, then raise the aim by 1/2 g t^2 so the ballistic rocket's arc passes
		# through it (rockets fall under ROCKET_GRAVITY; a flat aim lands short at range).
		var aim_pt: Vector3 = vv.pos + vel * flight
		aim_pt.y += 0.5 * ROCKET_GRAVITY * flight * flight
		# One refinement pass: the raised aim is slightly farther, so recompute flight + drop.
		flight = origin.distance_to(aim_pt) / ROCKET_SPEED
		aim_pt = vv.pos + vel * flight
		aim_pt.y += 0.5 * ROCKET_GRAVITY * flight * flight
		var dir := aim_pt - origin
		if dir.length() < 0.001: return
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, dir.normalized(), 0), 0)
		bot["rpg_last_tick"] = now
		return
	# Fallback: no enemy vehicle in range — lob a rocket at the nearest structural building piece
	# (building_id != 0) within RPG range. This is a best-effort heuristic to help bots chip away
	# at destructible cover near contested points. Strictly additive; does NOT alter vehicle logic.
	_maybe_rpg_building(bot, me)

## Heuristic fallback for _maybe_rpg: find the nearest structural building piece within
## VEHICLE_RPG_RANGE, aim at its cell centre (with rocket-drop compensation), and fire.
## Guards against null structs, empty mirrors, and non-engineer bots (caller already checks class).
func _maybe_rpg_building(bot: Dictionary, me: EntityState) -> void:
	var now := int(bot["server_tick"])
	if now - int(bot["rpg_last_tick"]) < RPG_FIRE_COOLDOWN: return
	var structs: Dictionary = bot["structs"]
	if structs.is_empty(): return
	# Find the nearest structural piece (building_id != 0) within range.
	var best_id := 0
	var best_d := VEHICLE_RPG_RANGE
	for sid in structs:
		var rec: Dictionary = structs[sid]
		if int(rec.get("building_id", 0)) == 0: continue   # skip non-building pieces
		var cell: Vector3i = rec["cell"]
		var wp: Vector3 = BuildGrid.world_of(cell)
		var d: float = me.pos.distance_to(wp)
		if d < best_d:
			best_d = d; best_id = sid
	if best_id == 0: return   # no structural piece in range
	var target_cell: Vector3i = structs[best_id]["cell"]
	var target_wp: Vector3 = BuildGrid.world_of(target_cell)
	var origin := me.pos
	var flight: float = origin.distance_to(target_wp) / ROCKET_SPEED
	# Apply the same ballistic drop compensation as the vehicle path — raise the aim so the
	# rocket's arc passes through the target rather than falling short.
	var aim_pt := target_wp
	aim_pt.y += 0.5 * ROCKET_GRAVITY * flight * flight
	# One refinement pass (mirrors vehicle path).
	flight = origin.distance_to(aim_pt) / ROCKET_SPEED
	aim_pt = target_wp
	aim_pt.y += 0.5 * ROCKET_GRAVITY * flight * flight
	var dir := aim_pt - origin
	if dir.length() < 0.001: return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, dir.normalized(), 0), 0)
	bot["rpg_last_tick"] = now

## Engineer C4: an engineer who chose C4 (gadget_for_player → C4) places one near a structure
## between us and the enemy, then detonates it next pass.
func _maybe_c4(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if Loadout.gadget_for_player(int(bot["class"]), int(bot["id"])) != Loadout.GADGET_C4: return
	if not bool(bot["c4_placed"]):
		if not _cover_between(bot, me.pos, target.pos): return
		var place := me.pos + (target.pos - me.pos).normalized() * 2.0
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_C4_PLACE, place, Vector3.ZERO, 0), 0)
		bot["c4_placed"] = true
	elif not bool(bot["c4_detonated"]):
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_C4_DETONATE, Vector3.ZERO, Vector3.ZERO, 0), 0)
		bot["c4_detonated"] = true

## Engineer claymore: an engineer who chose the claymore (gadget_for_player → MINE) drops one
## facing `toward` (the current enemy when fighting, else the contested objective) — the claymore
## sits between the engineer and where enemies advance from, so an attacker (or the bot's own
## killer pushing in) crosses the 1.5 m trip cone. Re-placed each life (flags reset on death),
## so claymores keep appearing along the front rather than one stale one per match.
func _maybe_mine(bot: Dictionary, me: EntityState, toward: Vector3) -> void:
	if Loadout.gadget_for_player(int(bot["class"]), int(bot["id"])) != Loadout.GADGET_MINE or bool(bot["mine_placed"]): return
	var to_t := Vector3(toward.x - me.pos.x, 0.0, toward.z - me.pos.z)
	var face := to_t.normalized() if to_t.length() > 0.001 else Vector3(sin(me.yaw), 0.0, cos(me.yaw))
	# Place toward `toward`, within the server's 2.0 m place_range.
	var place := me.pos + face * minf(1.8, maxf(to_t.length(), 0.001))
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_MINE_PLACE, place, face, 0), 0)
	bot["mine_placed"] = true

## Medic/Support: if a same-team mate within give range is hurt, aim at them and hold the active
## give for a short window; also throw a bag the first time so the thrown-bag path is exercised.
func _maybe_give(bot: Dictionary, me: EntityState) -> void:
	if bot["class"] != Loadout.MEDIC and bot["class"] != Loadout.SUPPORT: return
	var view: Dictionary = bot["view"]
	var best := 0
	var best_d := 3.0
	for id in view:
		if id == bot["id"]: continue
		var e: EntityState = view[id]
		if not e.alive or e.is_downed or e.team != me.team: continue
		var d: float = me.pos.distance_to(e.pos)
		if d <= best_d:
			best_d = d; best = id
	if best == 0:
		if int(bot["gave_until"]) != 0:
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_gadget_action(Protocol.GA_GIVE_STOP, Vector3.ZERO, Vector3.ZERO, 0), 0)
			bot["gave_until"] = 0
		return
	var tpos: Vector3 = (view[best] as EntityState).pos
	var aim := tpos - me.pos
	bot["yaw"] = atan2(aim.x, aim.z)
	bot["pitch"] = clampf(asin(clampf(aim.y / maxf(aim.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_GIVE_START, Vector3.ZERO, aim.normalized(), best), 0)
	if int(bot["gave_until"]) == 0:
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
			Protocol.encode_gadget_action(Protocol.GA_BAG_THROW, tpos, Vector3.ZERO, 0), 0)
		bot["gave_until"] = 1

## True if any known structure's cell-centre lies near the segment from `a` to `b` (coarse: the
## bot only knows piece positions from its mirror, not exact AABBs). Bounds the throw to useful cases.
func _cover_between(bot: Dictionary, a: Vector3, b: Vector3) -> bool:
	var seg := b - a
	var seg_len := seg.length()
	if seg_len < 0.001:
		return false
	var n := seg / seg_len
	for id in bot["structs"]:
		var cell: Vector3i = bot["structs"][id]["cell"]
		var c := BuildGrid.cell_min(cell) + Vector3.ONE * (BuildGrid.CELL_SIZE * 0.5)
		var t := clampf((c - a).dot(n), 0.0, seg_len)
		if (a + n * t).distance_to(c) <= BuildGrid.CELL_SIZE:   # within ~one cell of the line
			return true
	return false

func _objective_pos(me: EntityState) -> Vector3:
	if _map == null or _map.points.is_empty():
		return me.pos
	var positions: Array = []
	var owners: Array = []
	for i in _map.points.size():
		positions.append(_map.points[i]["pos"])
		owners.append(int(_match_points[i]["owner"]) if i < _match_points.size() else -1)
	# Target the nearest non-owned point to this bot (center == from). Bots capture their
	# backfield then push to the middle; this yields real captures (and flag deficits ->
	# ticket bleed). A map-centre bias was tried but funnelled both teams onto the single
	# centre point, which stayed perpetually contested and never captured.
	var idx := AiObjective.choose_objective_index(positions, owners, me.team, me.pos, me.pos)
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

func _send(bot: Dictionary, mx: float, my: float, yaw: float, pitch: float, buttons: int) -> void:
	var bytes := InputCommand.encode(bot["tick"], bot["last_seq"], mx, my, yaw, pitch, buttons, bot["server_tick"])
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)

func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var w := Protocol.decode_welcome(bytes)
			bot["id"] = int(w["id"])
			bot["class"] = int(w["class"])
			bot["connected"] = true
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
