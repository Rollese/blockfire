extends Node
## Headless bot fleet. Each bot is a real client that decodes its interest view and
## fights the nearest enemy. Many bots per process (load + playtest). See M2 spec.

const Protocol := preload("res://shared/net/protocol.gd")
const AIM_TOLERANCE := 0.05   # radians; fire when aim within this of target
const ENGAGE_RANGE := 50.0   # only fire once within this range (else keep closing)

var _server_ip := "127.0.0.1"
var _port := 27015
var _bot_count := 1
var _bots: Array[Dictionary] = []

func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_bot_count = maxi(1, int(args.get("bot-count", _bot_count)))

func _ready() -> void:
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

	if target != null:
		var d := target.pos - me.pos
		var want_yaw := atan2(d.x, d.z)
		var want_pitch := clampf(asin(clampf(d.y / maxf(d.length(), 0.001), -1.0, 1.0)), -Pawn.MAX_PITCH, Pawn.MAX_PITCH)
		bot["yaw"] = lerp_angle(bot["yaw"], want_yaw, 0.5) + randf_range(-0.003, 0.003)
		bot["pitch"] = lerpf(bot["pitch"], want_pitch, 0.5)
		# move toward the target in WORLD space (Pawn movement is world-space planar)
		var flat := Vector2(d.x, d.z)
		if flat.length() > 0.001:
			flat = flat.normalized()
		move_x = flat.x
		move_y = flat.y
		var yaw_ok := absf(angle_diff(bot["yaw"], want_yaw)) < AIM_TOLERANCE
		var pitch_ok := absf(want_pitch - bot["pitch"]) < AIM_TOLERANCE
		if best <= ENGAGE_RANGE and yaw_ok and pitch_ok:
			buttons |= InputCommand.BTN_FIRE
	else:
		# no enemy in view: advance toward the enemy side (world +x for team 0, -x for team 1)
		# so the two teams converge and make contact, with slight z wander.
		var adv_x := 1.0 if me.team == 0 else -1.0
		move_x = adv_x
		move_y = randf_range(-0.3, 0.3)
		bot["yaw"] = atan2(move_x, move_y)

	_send(bot, move_x, move_y, bot["yaw"], bot["pitch"], buttons)

func angle_diff(a: float, b: float) -> float:
	return wrapf(a - b, -PI, PI)

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
		_:
			pass

func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]: n += 1
	return n
