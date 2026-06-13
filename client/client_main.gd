extends Node
## Client. M1 (headless): connect, send input frames, ack + apply snapshots,
## reconcile own pawn, interpolate remotes. Rendering/real input arrive in M2.

const Protocol := preload("res://shared/net/protocol.gd")

var _net: NetHost
var _server_ip := "127.0.0.1"
var _port := 27015
var _player_name := "Player"
var _peer: ENetPacketPeer

var my_id := 0
var _client_tick := 0
var _last_snapshot_seq := 0
var _view := {}                     # id -> EntityState (authoritative, pre-interp)
var _pred := Prediction.new()
var _interp := Interpolation.new()
var _elapsed := 0.0
var _log_accum := 0.0


func configure(args: Dictionary) -> void:
	_server_ip = String(args.get("connect", _server_ip))
	_port = int(args.get("port", _port))
	_player_name = String(args.get("name", _player_name))


func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(_on_connected)
	_net.packet_received.connect(_on_packet)
	_peer = _net.start_client(_server_ip, _port)
	if _peer == null:
		push_error("[client] failed to create client host")
		return
	print("[client] connecting to %s:%d ..." % [_server_ip, _port])


func _physics_process(delta: float) -> void:
	_net.poll()
	_elapsed += delta
	if my_id != 0:
		_client_tick += 1
		# M1: neutral input (no input device headless). M2 reads real input here.
		var move_x := 0.0
		var move_y := 0.0
		var yaw := 0.0
		_pred.record_input(_client_tick, move_x, move_y, yaw)
		_net.send_to(_peer, NetHost.CHANNEL_INPUT,
			InputCommand.encode(_client_tick, _last_snapshot_seq, move_x, move_y, yaw, 0.0, 0),
			0)  # unreliable-sequenced
	_log_accum += delta
	if _log_accum >= 2.0 and my_id != 0:
		print("[client] id=%d tick=%d view_entities=%d pred_pos=%s"
			% [my_id, _client_tick, _view.size(), str(_pred.predicted.pos)])
		_log_accum = 0.0


func _on_connected(peer: ENetPacketPeer) -> void:
	_net.send_to(peer, NetHost.CHANNEL_CONTROL,
		Protocol.encode_hello(_player_name), ENetPacketPeer.FLAG_RELIABLE)


func _on_packet(_peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.WELCOME:
			var r := Protocol.body_reader(bytes)
			my_id = r.get_u32()
			print("[client] WELCOME — id=%d, server tick=%dHz" % [my_id, r.get_u16()])
		Protocol.Msg.REJECT:
			print("[client] REJECTED: %s" % Protocol.body_reader(bytes).get_utf8_string())
		Protocol.Msg.SNAPSHOT:
			_apply_snapshot(bytes)


func _apply_snapshot(bytes: PackedByteArray) -> void:
	var hdr := Snapshot.decode_apply(bytes, _view)
	_last_snapshot_seq = maxi(_last_snapshot_seq, int(hdr["seq"]))
	# reconcile own pawn if present in the authoritative view
	if _view.has(my_id):
		var mine: EntityState = _view[my_id]
		_pred.reconcile(mine.pos, mine.yaw, int(hdr["last_input_tick"]))
	# feed remote entities (everyone but me) into interpolation
	var remotes := {}
	for id in _view:
		if id != my_id:
			remotes[id] = (_view[id] as EntityState).clone()
	_interp.push(_elapsed, remotes)
