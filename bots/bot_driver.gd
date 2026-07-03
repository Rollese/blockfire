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

var _map: MapDef
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
		"class": 0, "rpg_last_tick": -100000, "c4_placed": false, "c4_detonated": false,
		"mine_placed": false, "gave_until": 0, "give_target": 0,
		"vview": {}, "in_vehicle": 0, "boarded_origin": Vector3.ZERO, "repairing": false,
		"vveh_track": {},
		# M7.5-P3 support mirrors + latches: SELF_STATE dict, GADGET_LIST wholesale mirror,
		# GRENADE_FX landing ring; reviving_id = active REVIVE_ACTION latch, bandaged =
		# once-per-life self-bandage latch, last_bag_tick = needs-driven bag-deploy cooldown.
		"self_state": {}, "gadgets": [], "grenade_events": [],
		"reviving_id": 0, "bandaged": false, "last_bag_tick": -100000,
		"ai": AiDriver.new(_global_seed, index, _ai_profile),
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
		bot["fob_drill_start"] = -1   # M12-P3: re-evaluate the FOB drill fresh on the next spawn
		bot["cur_swap_slot"] = 0   # server resets active_slot to 0 on (re)spawn; mirror it
		bot["give_target"] = 0   # server clears the give latch on death; mirror it
		bot["bandaged"] = false   # M7.5-P3: re-arm the once-per-life self-bandage on respawn
		bot["reviving_id"] = 0   # M7.5-P3: server drops the revive on reviver death; mirror it
		(bot["ai"] as AiDriver).reset()   # re-arm reaction gate, drop stale tracks/behaviour latch
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# DBNO: downed pawns are immune to weapon damage, so a downed bot holds still and waits to be
	# revived. M7.5-P3 (ratified): it self-bandages ONCE per life when it still has a bandage, the
	# bleed is not already halted, and no teammate is mid-revive — bandages are finite, so matches
	# still end by bleed-out once they are spent (give-up behaviour unchanged).
	if me.is_downed:
		var ss: Dictionary = bot["self_state"]
		if not bool(bot.get("bandaged", false)) and AiSupport.should_self_bandage(true,
				int(ss.get("bandage_count", 0)), bool(ss.get("bleed_halted", false)),
				bool(ss.get("being_revived", false))):
			(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
				Protocol.encode_self_bandage(), 0)
			bot["bandaged"] = true
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	var role: int = BotRolesRef.of(int(bot["index"]))
	var is_crew := role == BotRolesRef.CREW
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

	# Build cover only while stationary (holding a point or firing) — so the bot drops a wall
	# toward the contested objective without walking into its own piece, and the cover lands in
	# the combat zone where shots cross it. (Marching bots move, so this won't fire mid-route.)
	if move_x == 0.0 and move_y == 0.0:
		_ex.maybe_build(bot, me)
		_ex.maybe_mine(bot, me, obj)

	_ex.maybe_rpg(bot, me)
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
		Protocol.Msg.GRENADE_FX:
			# A remote pawn threw a grenade: stamp a flat GRENADE_LANDING_EST-ahead landing
			# estimate into a small ring; AiSupport.danger_zones expires entries by tick.
			# FRAG only — the server also broadcasts SMOKE arcs (harmless; own team smokes
			# objectives constantly, and fleeing those would scatter every push).
			var g := Protocol.decode_grenade_fx(bytes)
			if int(g["kind"]) == Grenade.FRAG:
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
