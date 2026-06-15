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
		_send(bot, 0.0, 0.0, bot["yaw"], 0.0, 0)
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
	if target != null:
		var d := target.pos - me.pos
		var want_yaw := atan2(d.x, d.z)
		var want_pitch := clampf(asin(clampf(d.y / maxf(d.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
		bot["yaw"] = lerp_angle(bot["yaw"], want_yaw, 0.5) + randf_range(-0.003, 0.003)
		bot["pitch"] = lerpf(bot["pitch"], want_pitch, 0.5)
		var yaw_ok := absf(angle_diff(bot["yaw"], want_yaw)) < AIM_TOLERANCE
		var pitch_ok := absf(want_pitch - bot["pitch"]) < AIM_TOLERANCE
		var fire := best <= ENGAGE_RANGE and yaw_ok and pitch_ok
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
	else:
		# no enemy in view: march to the objective (capture/defend)
		var flat := Vector2(obj.x - me.pos.x, obj.z - me.pos.z)
		if flat.length() > 0.001: flat = flat.normalized()
		move_x = flat.x; move_y = flat.y
		bot["yaw"] = atan2(move_x, move_y)

	# Build cover only while stationary (holding a point or firing) — so the bot drops a wall
	# toward the contested objective without walking into its own piece, and the cover lands in
	# the combat zone where shots cross it. (Marching bots move, so this won't fire mid-route.)
	if move_x == 0.0 and move_y == 0.0:
		_maybe_build(bot, me)

	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

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
			bot["id"] = Protocol.body_reader(bytes).get_u32()
			bot["connected"] = true
			print("[bots] bot %d connected (id %d) — %d/%d" % [bot["index"], bot["id"], _connected_count(), _bot_count])
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
