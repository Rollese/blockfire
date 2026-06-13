extends Node
## Dedicated authoritative server (headless, Linux). 30 Hz tick.
## M0: accepts connections, completes the handshake, tracks peers.
## M1: owns the authoritative SimLoop and emits snapshots. See M1 milestone.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128

var _net: NetHost
var _port := 27015
var _peer_ids := {}   ## ENetPacketPeer -> assigned peer id
var _next_id := 1


func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))


func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_peer_connected)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)

	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] failed to bind port %d: %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return
	print("[server] listening on port %d, tick=%dHz, max=%d" % [_port, TICK_RATE, MAX_PLAYERS])


func _physics_process(_delta: float) -> void:
	_net.poll()
	# M1: step authoritative SimLoop here and broadcast snapshots.


func _on_peer_connected(_peer: ENetPacketPeer) -> void:
	print("[server] peer connected (awaiting HELLO)")


func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id: int = _peer_ids.get(peer, 0)
	_peer_ids.erase(peer)
	print("[server] peer %d disconnected — %d peers" % [id, _peer_ids.size()])


func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO:
			_handle_hello(peer, bytes)
		_:
			pass  # M1: input command frames, etc.


func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_reject("protocol version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	if _peer_ids.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL,
			Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	var id := _next_id
	_next_id += 1
	_peer_ids[peer] = id
	_net.send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') — %d peers" % [id, pname, _peer_ids.size()])
