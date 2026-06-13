extends Node
## Player-facing client. M0: connects to the server and completes the handshake.
## M1: runs client-side prediction + interpolation; M2+: rendering, input, UI.

const Protocol := preload("res://shared/net/protocol.gd")

var _net: NetHost
var _server_ip := "127.0.0.1"
var _port := 27015
var _player_name := "Player"
var _peer: ENetPacketPeer
var _connected := false
var my_id := 0
var server_tick_rate := 0


func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_player_name = String(args.get("name", _player_name))


func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_connected)
	_net.peer_disconnected.connect(_on_disconnected)
	_net.packet_received.connect(_on_packet)

	_peer = _net.start_client(_server_ip, _port)
	if _peer == null:
		push_error("[client] failed to create client host")
		return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])


func _physics_process(_delta: float) -> void:
	_net.poll()


func _on_connected(peer: ENetPacketPeer) -> void:
	print("[client] transport connected, sending HELLO")
	_net.send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_hello(_player_name), ENetPacketPeer.FLAG_RELIABLE)


func _on_disconnected(_peer: ENetPacketPeer) -> void:
	_connected = false
	print("[client] disconnected from server")


func _on_packet(_peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			my_id = r.get_u32()
			server_tick_rate = r.get_u16()
			_connected = true
			print("[client] WELCOME — id=%d, server tick=%dHz" % [my_id, server_tick_rate])
		Protocol.Msg.REJECT:
			var r := Protocol.body_reader(bytes)
			print("[client] REJECTED: %s" % r.get_utf8_string())
