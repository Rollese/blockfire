extends Node
## Headless bot fleet. Each bot is a real client that decodes its interest view and
## fights the nearest enemy. Many bots per process (load + playtest). See M2 spec.

const Protocol := preload("res://shared/net/protocol.gd")
const AIM_TOLERANCE := 0.05   # radians; fire when aim within this of target
const ENGAGE_RANGE := 50.0   # only fire once within this range (else keep closing)
const MAP_PATH := "res://maps/conquest_proving_grounds.json"
const BURST_TICKS := 60   # server ticks (~2.0s @30Hz) of firing before reloading; shorter
                          # than the fastest mag-empty time so no weapon runs dry mid-burst
const RELOAD_TICKS := 84  # server ticks (~2.8s) to hold BTN_RELOAD; > the slowest weapon
                          # reload (2.6s) so the mag is surely refilled before the next burst
const BUILD_COOLDOWN_TICKS := 150   # match server StructureStore.BUILD_COOLDOWN_TICKS (5s)
const BUILD_DIST := 3.0             # how far ahead (m) to drop cover; within server BUILD_RANGE
const MAX_BOT_BUILDS := 1           # walls each bot drops before stopping. Keeps the contested
                                    # zone covered (cover blocks crossfire, so blk>0) without
                                    # boxing every bot in — combat still flows so attrition
                                    # converges the match to a winner. Tuned via the 48-bot smoke.
const GRENADE_COOLDOWN_TICKS := 300   # match server GRENADE_COOLDOWN_TICKS (10s, shared frag/smoke)
const MAX_BOT_GRENADES := 1           # per-bot lifetime FRAG cap (convergence/over-destruction knob)
const MAX_BOT_SMOKES := 1             # per-bot lifetime SMOKE cap (exercises the smoke path)

var _map: MapDef
var _match_points: Array = []   # array of {owner, attacker, cap}, index == map point index
var _synced_logged := false   # logs once when any bot first sees a structure (gate signal)

var _server_ip := "127.0.0.1"
var _port := 27015
var _bot_count := 1
var _bots: Array[Dictionary] = []

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_bot_count = maxi(1, int(args.get("bot-count", _bot_count)))

func _ready() -> void:
	_map = MapDef.load_file(MAP_PATH)
	if _map == null:
		push_error("[bots] failed to load map %s" % MAP_PATH)
	print("[bots] spawning %d bot(s) -> %s:%d" % [_bot_count, _server_ip, _port])
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
		"class": 0, "rpg_fired": false, "c4_placed": false, "c4_detonated": false,
		"mine_placed": false, "gave_until": 0,
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void: _on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)

func _physics_process(delta: float) -> void:
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]: continue
		bot["tick"] += 1
		_drive(bot, delta)

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
		bot["rpg_fired"] = false
		bot["c4_placed"] = false
		bot["c4_detonated"] = false
		bot["mine_placed"] = false
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# DBNO: downed pawns are immune to weapon damage, so a downed bot holds still and waits to be
	# revived. It does NOT self-bandage — halting the bleed under the immune model would make it
	# immortal and stall the match; instead it bleeds out if no teammate reaches it in time.
	if me.is_downed:
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
		return

	# Revive a downed teammate if one is close enough.
	var rid := _nearest_downed_teammate(bot, me)
	if rid != 0:
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

	var target: EntityState = null
	var best := INF
	for id in view:
		if id == bot["id"]: continue
		var e: EntityState = view[id]
		if not e.alive or e.team == me.team: continue
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
		_drill_ladder = _map.ladders[0]
		for pb in _map.prebuilt:
			if String(pb["type"]) == "sandbag":
				_drill_sandbag = BuildGrid.world_of(pb["cell"] as Vector3i)
				drill_geom_valid = true
				break

	if target != null:
		var d := target.pos - me.pos
		var want_yaw := atan2(d.x, d.z)
		var want_pitch := clampf(asin(clampf(d.y / maxf(d.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
		bot["yaw"] = lerp_angle(bot["yaw"], want_yaw, 0.5) + randf_range(-0.003, 0.003)
		bot["pitch"] = lerpf(bot["pitch"], want_pitch, 0.5)
		var yaw_ok := absf(angle_diff(bot["yaw"], want_yaw)) < AIM_TOLERANCE
		var pitch_ok := absf(want_pitch - bot["pitch"]) < AIM_TOLERANCE
		var fire := best <= ENGAGE_RANGE and yaw_ok and pitch_ok
		# Drillers override movement to continue the drill; non-drillers use the normal enemy-chase.
		if is_driller and drill_geom_valid:
			var phase: int = int(bot.get("drill_phase", DRILL_CLIMB))
			var dr := drill_step(phase, me.pos, _drill_ladder, _drill_sandbag)
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
			# Hold still while shooting (the server adds movement spread, so a moving bot barely
			# hits); otherwise close on the enemy in range, else advance on the objective.
			if fire:
				move_x = 0.0; move_y = 0.0
			else:
				var move_to: Vector3 = target.pos if best <= ENGAGE_RANGE else obj
				var flat := Vector2(move_to.x - me.pos.x, move_to.z - me.pos.z)
				if flat.length() > 0.001: flat = flat.normalized()
				move_x = flat.x; move_y = flat.y
		var cb := combat_button(fire, bot["server_tick"], bot["reload_until"], bot["burst_start"])
		buttons |= int(cb[0])
		bot["reload_until"] = cb[1]
		bot["burst_start"] = cb[2]
		_maybe_grenade(bot, me, target)
		_maybe_rpg(bot, me, target)
		_maybe_c4(bot, me, target)
		_maybe_mine(bot, me, target.pos)   # face the claymore at the enemy we're fighting
	else:
		# no enemy in view
		if is_driller and drill_geom_valid:
			# Driller: march the obstacle course instead of toward the capture objective.
			var phase: int = int(bot.get("drill_phase", DRILL_CLIMB))
			var dr := drill_step(phase, me.pos, _drill_ladder, _drill_sandbag)
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
			# Normal: march to the objective (capture/defend)
			var seek := climb_seek(me.pos, obj, _map.ladders if _map != null else [])
			if seek["seek"]:
				var lb: Vector3 = seek["target"]
				var flat2 := Vector2(lb.x - me.pos.x, lb.z - me.pos.z)
				if flat2.length() > 0.001: flat2 = flat2.normalized()
				move_x = flat2.x
				move_y = absf(flat2.y) + 1.0   # bias forward/up so climb engages and continues
				bot["yaw"] = atan2(move_x, flat2.y)
			else:
				var flat := Vector2(obj.x - me.pos.x, obj.z - me.pos.z)
				if flat.length() > 0.001: flat = flat.normalized()
				move_x = flat.x; move_y = flat.y
				bot["yaw"] = atan2(move_x, move_y)
			_maybe_smoke(bot, me, obj)

	# Build cover only while stationary (holding a point or firing) — so the bot drops a wall
	# toward the contested objective without walking into its own piece, and the cover lands in
	# the combat zone where shots cross it. (Marching bots move, so this won't fire mid-route.)
	if move_x == 0.0 and move_y == 0.0:
		_maybe_build(bot, me)
		_maybe_mine(bot, me, obj)

	_maybe_give(bot, me)
	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

## Advance a driller's phase state. If the phase changed, reset the tick counter. If the phase
## has not changed but the tick counter exceeded DRILL_PHASE_TIMEOUT, force-advance to the next
## phase and reset — so a stuck driller (killed mid-traverse, geometry blocked) never stalls.
func _update_drill_phase(bot: Dictionary, next_phase: int) -> void:
	var cur_phase: int = int(bot.get("drill_phase", DRILL_CLIMB))
	var ticks: int = int(bot.get("drill_phase_ticks", 0))
	if next_phase != cur_phase:
		# Phase transition from drill_step logic.
		bot["drill_phase"] = next_phase
		bot["drill_phase_ticks"] = 0
	else:
		ticks += 1
		if ticks >= DRILL_PHASE_TIMEOUT:
			# Stuck: force the other phase and reset.
			bot["drill_phase"] = DRILL_VAULT if cur_phase == DRILL_CLIMB else DRILL_CLIMB
			bot["drill_phase_ticks"] = 0
		else:
			bot["drill_phase_ticks"] = ticks

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

## Engineer RPG: fire once at an in-range enemy via GADGET_ACTION. The server rejects it unless the
## bot actually has the RPG equipped (it assigned ~1/3 of Engineers the RPG), so non-RPG bots no-op.
func _maybe_rpg(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if bot["class"] != Loadout.ENGINEER or bool(bot["rpg_fired"]): return
	var d := target.pos - me.pos
	if d.length() < 0.001 or d.length() > 60.0: return
	(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT,
		Protocol.encode_gadget_action(Protocol.GA_RPG_FIRE, Vector3.ZERO, d.normalized(), 0), 0)
	bot["rpg_fired"] = true

## Engineer C4: place one near a structure between us and the enemy, then detonate it next pass.
func _maybe_c4(bot: Dictionary, me: EntityState, target: EntityState) -> void:
	if bot["class"] != Loadout.ENGINEER: return
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

## Recon claymore: drop one facing `toward` (the current enemy when fighting, else the contested
## objective) — claymore sits between the Recon and where enemies advance from, so an attacker
## (or the bot's own killer pushing in) crosses the 1.5 m trip cone. Re-placed each life (flags
## reset on death), so claymores keep appearing along the front rather than one stale one per match.
func _maybe_mine(bot: Dictionary, me: EntityState, toward: Vector3) -> void:
	if bot["class"] != Loadout.RECON or bool(bot["mine_placed"]): return
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

func angle_diff(a: float, b: float) -> float:
	return wrapf(a - b, -PI, PI)

## Pure objective selector (unit-tested). Among points NOT owned by `my_team`, pick the one
## nearest `center` (tie-broken by distance from `from`); if the team owns every point,
## defend the nearest point to `from`. `owners[i]` is the owner of points[i] (-1 neutral);
## owners shorter than points defaults missing entries to neutral. Returns -1 iff points is
## empty. Biasing toward the map center makes both teams contest the same points so the match
## converges into combat. See docs/specs/m3-bot-convergence-fix.md.
static func choose_objective_index(points: Array, owners: Array, my_team: int, from: Vector3, center: Vector3) -> int:
	if points.is_empty():
		return -1
	var best := -1
	var best_c := INF
	var best_d := INF
	for i in points.size():
		var owner := -1
		if i < owners.size():
			owner = int(owners[i])
		if owner == my_team:
			continue   # already ours — skip while capturable points remain
		var cd: float = center.distance_to(points[i])
		var fd: float = from.distance_to(points[i])
		if cd < best_c - 0.001 or (absf(cd - best_c) <= 0.001 and fd < best_d):
			best_c = cd; best_d = fd; best = i
	if best == -1:
		# team owns every capturable point: defend the nearest one to `from`
		for i in points.size():
			var fd: float = from.distance_to(points[i])
			if fd < best_d:
				best_d = fd; best = i
	return best

const DRILL_CLIMB := 0   # drill phase: go climb the ladder
const DRILL_VAULT := 1   # drill phase: go vault the sandbag
const DRILL_PHASE_TIMEOUT := 1500   # ticks (~50 s @30Hz): reset stuck driller to next phase

const CLIMB_SEEK_RANGE := 16.0   # m: consider a ladder only when this close to its base
const CLIMB_TOP_MARGIN := 2.0    # m above the ladder bottom past which the bot is "up" already

## Decide whether to steer onto a ladder. seek=true with a move target at the ladder base when the
## bot is near a ladder (and still below it) and its objective is roughly across/beyond that ladder.
## Pure + unit-tested. The height guard stops a bot that has reached the ledge from re-seeking the
## same ladder and getting stuck pushing "up" at the top.
static func climb_seek(my_pos: Vector3, objective: Vector3, ladders: Array) -> Dictionary:
	for l in ladders:
		var base: Vector3 = l["bottom"]
		if my_pos.y > base.y + CLIMB_TOP_MARGIN:
			continue   # already elevated (on/above the ledge) — don't re-seek this ladder
		var to_base := Vector2(base.x - my_pos.x, base.z - my_pos.z)
		if to_base.length() > CLIMB_SEEK_RANGE:
			continue
		var to_obj := Vector2(objective.x - my_pos.x, objective.z - my_pos.z)
		# Objective is beyond the ladder (same general heading, farther away).
		if to_obj.length() > to_base.length() and to_base.normalized().dot(to_obj.normalized()) > 0.3:
			return {"seek": true, "target": base}
	return {"seek": false, "target": my_pos}

## Pure driller steering. phase 0 = go climb the ladder, phase 1 = go vault the sandbag.
## Returns {"move_to": Vector3, "force_climb": bool, "next_phase": int}.
## - CLIMB: steer toward the ladder base. force_climb=true once horizontally within (radius+0.5)
##   of the base. next_phase flips to VAULT once my_pos.y >= top.y - 0.3 (reached the top).
## - VAULT: steer toward the sandbag world point. next_phase flips back to CLIMB once
##   horizontally within ~1.5 m of the sandbag (vaulted past it).
static func drill_step(phase: int, my_pos: Vector3, ladder: Dictionary, sandbag_world: Vector3) -> Dictionary:
	if phase == DRILL_CLIMB:
		var base: Vector3 = ladder["bottom"]
		var top: Vector3 = ladder["top"]
		var radius: float = float(ladder["radius"])
		# Check if we've reached the ladder top (done climbing).
		if my_pos.y >= top.y - 0.3:
			return {"move_to": base, "force_climb": true, "next_phase": DRILL_VAULT}
		# Check horizontal distance to the base for force-climb engagement.
		var horiz_dist := Vector2(my_pos.x - base.x, my_pos.z - base.z).length()
		var force_climb := horiz_dist <= radius + 0.5
		return {"move_to": base, "force_climb": force_climb, "next_phase": DRILL_CLIMB}
	else:
		# VAULT phase: steer toward the sandbag; once within 1.5 m (vaulted past it), reset.
		var horiz_dist := Vector2(my_pos.x - sandbag_world.x, my_pos.z - sandbag_world.z).length()
		if horiz_dist <= 1.5:
			return {"move_to": sandbag_world, "force_climb": false, "next_phase": DRILL_CLIMB}
		return {"move_to": sandbag_world, "force_climb": false, "next_phase": DRILL_VAULT}

## Combat button for an ammo-blind bot, paced in SERVER game-time (`st` = server tick).
## Returns [button, reload_until, burst_start]. Fires BURST_TICKS-long bursts then holds
## BTN_RELOAD for RELOAD_TICKS before the next burst, so combat is sustained instead of dying
## after one magazine. See docs/specs/m3-bot-convergence-fix.md.
static func combat_button(fire: bool, st: int, reload_until: int, burst_start: int) -> Array:
	if st < reload_until:
		return [InputCommand.BTN_RELOAD, reload_until, burst_start]
	if not fire:
		return [0, reload_until, burst_start]
	if burst_start < 0:
		burst_start = st
	if st - burst_start >= BURST_TICKS:
		return [InputCommand.BTN_RELOAD, st + RELOAD_TICKS, -1]
	return [InputCommand.BTN_FIRE, reload_until, burst_start]

## Apply a decoded STRUCTURE_DELTA to a bot's local mirror (id->record). PLACE inserts, DAMAGE
## updates the record's bucket in place (must NOT remove), REMOVE erases. Pure + unit-tested;
## the live path runs inside _on_packet. See docs/specs/destruction.md.
static func apply_structure_delta(structs: Dictionary, d: Dictionary) -> void:
	var op: int = d["op"]
	if op == Protocol.OP_PLACE:
		structs[d["rec"]["id"]] = d["rec"]
	elif op == Protocol.OP_DAMAGE:
		var id: int = d["id"]
		if structs.has(id):
			structs[id]["bucket"] = d["bucket"]
	else:
		structs.erase(d["id"])

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
	var idx := choose_objective_index(positions, owners, me.team, me.pos, me.pos)
	return positions[idx] if idx >= 0 else me.pos

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
			var hdr := Snapshot.decode_apply(bytes, bot["view"])
			bot["last_seq"] = maxi(bot["last_seq"], int(hdr["seq"]))
			bot["server_tick"] = int(hdr["server_tick"])
		Protocol.Msg.MATCH_STATE:
			_match_points = Protocol.decode_match_state(bytes)["points"]
		Protocol.Msg.STRUCTURE_DELTA:
			apply_structure_delta(bot["structs"], Protocol.decode_structure_delta(bytes))
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
