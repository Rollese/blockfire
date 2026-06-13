extends Node
## Headless bot fleet. Each bot is a real client connection that sends random-walk
## input and acks snapshots without decoding the body (bots are load, not renderers).

const Protocol := preload("res://shared/net/protocol.gd")

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
		"tick": 0, "last_seq": 0, "heading": randf() * TAU, "turn_timer": 0.0,
	}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void:
		bot["peer"] = peer
		net.send_to(peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_hello("bot-%d" % index), ENetPacketPeer.FLAG_RELIABLE))
	net.peer_disconnected.connect(func(_p: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_p: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void:
		_on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)


func _physics_process(delta: float) -> void:
	for bot in _bots:
		(bot["net"] as NetHost).poll()
		if not bot["connected"]:
			continue
		bot["tick"] += 1
		bot["turn_timer"] -= delta
		if bot["turn_timer"] <= 0.0:
			bot["heading"] = randf() * TAU
			bot["turn_timer"] = randf_range(0.5, 2.0)
		var move_x: float = cos(bot["heading"])
		var move_y: float = sin(bot["heading"])
		var bytes := InputCommand.encode(bot["tick"], bot["last_seq"], move_x, move_y, bot["heading"], 0.0, 0)
		(bot["net"] as NetHost).send_to(bot["peer"], NetHost.CHANNEL_INPUT, bytes, 0)


func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			bot["id"] = r.get_u32()
			bot["connected"] = true
			print("[bots] bot %d connected (id %d) — %d/%d connected"
				% [bot["index"], bot["id"], _connected_count(), _bot_count])
		Protocol.Msg.SNAPSHOT:
			# cheap ack: read only seq (header bytes 5..8), ignore the body.
			var buf := StreamPeerBuffer.new()
			buf.data_array = bytes
			buf.seek(5)  # skip type(1) + server_tick(4)
			bot["last_seq"] = buf.get_u32()


func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]:
			n += 1
	return n
