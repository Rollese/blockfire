extends Node
## Dedicated authoritative server. 30 Hz. Spawns a pawn per peer, consumes one input
## per client per tick, steps the shared SimLoop, and sends per-client delta snapshots.
## See docs/specs/m1-netcode-core.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0

var _net: NetHost
var _port := 27015
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _tele := Telemetry.new()
var _next_id := 1
var _tele_accum := 0.0

# id -> client record
#   { peer, queued_input (Dictionary|null), last_input (Dictionary|null),
#     last_input_tick:int, last_acked_seq:int, next_seq:int,
#     history: Dictionary[seq -> Dictionary[id->EntityState]] }
var _clients := {}
var _peer_to_id := {}


func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))


func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)  # wait for HELLO before spawning
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)])
		get_tree().quit(1)
		return
	print("[server] listening on %d, tick=%dHz, max=%d" % [_port, TICK_RATE, MAX_PLAYERS])


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	_consume_inputs_and_step()
	_send_snapshots()
	_tele.record_tick_ms(float(Time.get_ticks_usec() - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry()
		_tele_accum = 0.0


func _consume_inputs_and_step() -> void:
	var inputs := {}
	for id in _clients:
		var c = _clients[id]
		var inp = c["queued_input"]
		if inp == null:
			inp = c["last_input"]
			if inp != null:
				_tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		c["queued_input"] = null
	_sim.step(inputs)


func _send_snapshots() -> void:
	var state := _sim.world.state_map()      # id -> EntityState (fresh clones)
	var positions := {}
	_grid.clear()
	for id in state:
		positions[id] = state[id].pos
		_grid.insert(id, state[id].pos)

	for id in _clients:
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null:
			continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, positions)
		var current := {}
		for vid in ids:
			current[vid] = state[vid]
		var baseline = c["history"].get(c["last_acked_seq"], {})
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, c["last_acked_seq"],
			c["last_input_tick"], current, baseline)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)  # unreliable-sequenced
		c["history"][seq] = current
		c["next_seq"] = seq + 1
		_tele.add_bytes(id, bytes.size())


func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO:
			_handle_hello(peer, bytes)
		Protocol.Msg.INPUT:
			_handle_input(peer, bytes)
		_:
			pass


func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	if _clients.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later()
		return
	var id := _next_id
	_next_id += 1
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null,
		"last_input_tick": 0, "last_acked_seq": 0, "next_seq": 1, "history": {},
	}
	var pawn := _sim.world.spawn(id)
	pawn.pos = Vector3(randf_range(-Pawn.WORLD_HALF, Pawn.WORLD_HALF), 0.0, randf_range(-Pawn.WORLD_HALF, Pawn.WORLD_HALF))
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') — %d peers" % [id, pname, _clients.size()])


func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id):
		return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	# stale/duplicate guard
	if c["queued_input"] != null and d["client_tick"] <= c["queued_input"]["client_tick"]:
		return
	c["queued_input"] = d
	# process the piggybacked snapshot ack: advance baseline, prune older history.
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack:
				c["history"].erase(s)


func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0:
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])


func _log_telemetry() -> void:
	var n := _clients.size()
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	print("[telemetry] players=%d tick_mean=%.2fms tick_p99=%.2fms peak=%dB/s agg=%.1fMbit/s starv=%d"
		% [n, _tele.mean_tick_ms(), _tele.p99_tick_ms(), _tele.peak_bytes_per_client(), mbit, _tele.starvation])
	_tele.reset_window()
