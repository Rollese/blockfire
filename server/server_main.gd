extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), minimal respawn. See docs/specs/m2-core-fps-loop.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0
const MAX_HISTORY := 32
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray

var _net: NetHost
var _port := 27015
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _next_id := 1
var _tele_accum := 0.0
var _team_counts := {0: 0, 1: 0}

var _kills := 0
var _shots := 0
var _hits := 0
var _rewind_clamped := 0

var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))

func _ready() -> void:
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d" % [_port, TICK_RATE, MAX_PLAYERS])

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	_step_movement()
	_lag.record(_sim.tick, _sim.world)
	_resolve_fires()
	_handle_respawns()
	_send_snapshots()
	_tele.record_tick_ms(float(Time.get_ticks_usec() - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0

func _step_movement() -> void:
	var inputs := {}
	for id in _clients:
		var c = _clients[id]
		var inp = c["queued_input"]
		if inp == null:
			inp = c["last_input"]
			if inp != null: _tele.starvation += 1
		if inp != null:
			inputs[id] = inp
			c["last_input"] = inp
			c["last_input_tick"] = inp["client_tick"]
		c["queued_input"] = null
		if c["reloading"] and _sim.tick >= c["reload_done_tick"]:
			c["reloading"] = false
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
	_sim.step(inputs)

func _resolve_fires() -> void:
	for id in _clients:
		var c = _clients[id]
		var inp = c["last_input"]
		if inp == null: continue
		var shooter: Pawn = _sim.world.get_pawn(id)
		if shooter == null or not shooter.alive: continue
		var firing: bool = (inp["buttons"] & InputCommand.BTN_FIRE) != 0
		if not firing:
			c["shot_index"] = 0
			c["trigger_down"] = false
			if (inp["buttons"] & InputCommand.BTN_RELOAD) and not c["reloading"] and c["ammo"] < Weapon.get_def(c["weapon"])["mag_size"]:
				c["reloading"] = true
				c["reload_done_tick"] = _sim.tick + int(round(Weapon.get_def(c["weapon"])["reload_secs"] * TICK_RATE))
			continue
		var now := float(_sim.tick) * SimLoop.DT
		var ready: bool = now - c["last_fire_time"] >= Weapon.fire_interval(c["weapon"])
		var sprinting: bool = (inp["buttons"] & InputCommand.BTN_SPRINT) and shooter.stance == Stance.STAND
		if c["reloading"] or c["ammo"] <= 0 or not ready or sprinting:
			continue
		c["last_fire_time"] = now
		c["ammo"] -= 1
		var shot_index: int = c["shot_index"]
		c["shot_index"] = shot_index + 1
		c["trigger_down"] = true
		_shots += 1
		_fire_shot(id, shooter, inp, shot_index)

func _fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = _clients[shooter_id]["weapon"]
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, inp["client_tick"], shot_index, moving)

	var view_tick: int = inp["view_server_tick"]
	if view_tick < _sim.tick - LagComp.MAX_REWIND or view_tick > _sim.tick:
		_rewind_clamped += 1
	var frame := _lag.rewind(view_tick)

	var max_range: float = Weapon.get_def(wid)["range_m"]
	var best_t := max_range + 1.0
	var best_victim := 0
	var best_head := false
	for tid in frame:
		if tid == shooter_id: continue
		var st = frame[tid]
		if not st["alive"] or st["team"] == shooter.team: continue
		var to_target: Vector3 = st["pos"] - ray["origin"]
		if to_target.length() > max_range: continue
		if to_target.normalized().dot(ray["dir"]) < FIRE_CONE_DOT: continue
		var hit := Hitbox.raycast_pawn(ray["origin"], ray["dir"], st["pos"], st["stance"], max_range)
		if hit["hit"] and hit["t"] < best_t:
			best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]
	if best_victim == 0:
		return
	_hits += 1
	var dmg := Combat.damage_for(wid, best_head, best_t)
	var victim: Pawn = _sim.world.get_pawn(best_victim)
	if victim == null or not victim.alive: return
	victim.health -= dmg
	if victim.health <= 0:
		victim.health = 0
		victim.alive = false
		_clients[best_victim]["respawn_tick"] = _sim.tick + RESPAWN_DELAY_TICKS
		_kills += 1
		var ev := Protocol.encode_kill(best_victim, shooter_id, wid, best_head)
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, ev, ENetPacketPeer.FLAG_RELIABLE)

func _handle_respawns() -> void:
	for id in _clients:
		var c = _clients[id]
		var p: Pawn = _sim.world.get_pawn(id)
		if p == null or p.alive: continue
		if c["respawn_tick"] > 0 and _sim.tick >= c["respawn_tick"]:
			p.pos = _spawn_pos(p.team)
			p.velocity = Vector3.ZERO
			p.health = 100
			p.alive = true
			p.stamina = Pawn.STAMINA_MAX
			c["respawn_tick"] = 0
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
			c["reloading"] = false

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	var positions := {}
	_grid.clear()
	for id in state:
		positions[id] = state[id].pos
		_grid.insert(id, state[id].pos)
	for id in _clients:
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, positions)
		var current := {}
		for vid in ids: current[vid] = state[vid]
		var baseline_seq: int = c["last_acked_seq"]
		var baseline = c["history"].get(baseline_seq)
		if baseline == null:
			baseline = {}; baseline_seq = 0
		var seq: int = c["next_seq"]
		var bytes := Snapshot.encode(_sim.tick, seq, baseline_seq, c["last_input_tick"], current, baseline)
		_net.send_to(c["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)
		c["history"][seq] = current
		c["next_seq"] = seq + 1
		var cutoff := seq - MAX_HISTORY
		for s in c["history"].keys():
			if s < cutoff: c["history"].erase(s)
		_tele.add_bytes(id, bytes.size())

func _on_packet(peer: ENetPacketPeer, _channel: int, bytes: PackedByteArray) -> void:
	match Protocol.msg_type(bytes):
		Protocol.Msg.HELLO: _handle_hello(peer, bytes)
		Protocol.Msg.INPUT: _handle_input(peer, bytes)
		_: pass

func _handle_hello(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var r := Protocol.body_reader(bytes)
	var ver := r.get_u16()
	var pname := r.get_utf8_string()
	if ver != Protocol.VERSION:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("version mismatch"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	if _clients.size() >= MAX_PLAYERS:
		_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_reject("server full"), ENetPacketPeer.FLAG_RELIABLE)
		peer.peer_disconnect_later(); return
	var id := _next_id
	_next_id += 1
	var team: int = 0 if _team_counts[0] <= _team_counts[1] else 1
	_team_counts[team] += 1
	var cls := Loadout.random_class()
	var wid := Loadout.weapon_for(cls)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {},
		"team": team, "class": cls, "weapon": wid, "ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "trigger_down": false, "respawn_tick": 0,
	}
	var p := _sim.world.spawn(id)
	p.team = team
	p.pos = _spawn_pos(team)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d class=%d — %d peers" % [id, pname, team, cls, _clients.size()])

func _handle_input(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var d := InputCommand.decode(bytes)
	var c = _clients[id]
	if c["queued_input"] != null and d["client_tick"] <= c["queued_input"]["client_tick"]: return
	c["queued_input"] = d
	var ack: int = d["ack_seq"]
	if ack > c["last_acked_seq"]:
		c["last_acked_seq"] = ack
		for s in c["history"].keys():
			if s < ack: c["history"].erase(s)

func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0 and _clients.has(id):
		_team_counts[_clients[id]["team"]] -= 1
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _spawn_pos(team: int) -> Vector3:
	# Two opposing zones spread along a wide z-front (low linear density keeps interest
	# cost / tick bounded, near M1's wide-spacing baseline) while still letting the teams
	# converge and fight. Tuned so the M2 gate holds 30Hz AND bots make contact.
	var x: float = randf_range(-400.0, -150.0) if team == 0 else randf_range(150.0, 400.0)
	return Vector3(x, 0.0, randf_range(-900.0, 900.0))

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var hit_rate := 0.0 if _shots == 0 else float(_hits) / float(_shots)
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped])
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0
