extends Node
## Headless bot driver. Simulates many bots per process, each a real client
## connection sharing the same protocol + (eventually) SimLoop as the real client.
## Dockerized into a fleet for stress + playtesting. See docs/adr/0002 and M1.
##
## M0: spawn N bots, connect each, complete the handshake. M2+: AI feeds input
## command frames (move to objective, shoot visible enemies, respawn).

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
	var bot := {"net": net, "index": index, "id": 0, "connected": false}
	net.peer_connected.connect(func(peer: ENetPacketPeer) -> void: _on_connected(bot, peer))
	net.peer_disconnected.connect(func(_peer: ENetPacketPeer) -> void: bot["connected"] = false)
	net.packet_received.connect(func(_peer: ENetPacketPeer, _ch: int, bytes: PackedByteArray) -> void:
		_on_packet(bot, bytes))
	net.start_client(_server_ip, _port)
	_bots.append(bot)


func _physics_process(_delta: float) -> void:
	for bot in _bots:
		(bot["net"] as NetHost).poll()
	# M2+: each bot steps its AI and sends an input command frame here.


func _on_connected(bot: Dictionary, peer: ENetPacketPeer) -> void:
	(bot["net"] as NetHost).send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_hello("bot-%d" % bot["index"]), ENetPacketPeer.FLAG_RELIABLE)


func _on_packet(bot: Dictionary, bytes: PackedByteArray) -> void:
	if Protocol.msg_type(bytes) == Protocol.Msg.WELCOME:
		var r := Protocol.body_reader(bytes)
		bot["id"] = r.get_u32()
		bot["connected"] = true
		print("[bots] bot %d connected (id %d) — %d/%d connected"
			% [bot["index"], bot["id"], _connected_count(), _bot_count])


func _connected_count() -> int:
	var n := 0
	for b in _bots:
		if b["connected"]:
			n += 1
	return n
