extends Node
## Dedicated authoritative server. 30 Hz. Movement + hit-scan combat with lag comp,
## teams (FF off), Conquest mode (capture points, tickets, win), squads, deploy/respawn.
## See docs/specs/m3-conquest-squads.md.

const Protocol := preload("res://shared/net/protocol.gd")

const TICK_RATE := 30
const MAX_PLAYERS := 128
const INTEREST_RADIUS := 250.0
const CELL_SIZE := 64.0
const MAX_HISTORY := 32
const SNAPSHOT_STRIDE := 2   # send each client a snapshot every Nth tick (round-robin by id),
                             # so per-tick encode cost is ~clients/STRIDE instead of O(clients).
                             # Client-side interpolation smooths the lower send rate (30/STRIDE Hz).
const MAX_SNAPSHOT_ENTITIES := 32   # relevance cap: a snapshot carries at most the N most
                                    # relevant entities (enemies first, then nearest teammates),
                                    # bounding the worst case (a dense cluster) where every client
                                    # would otherwise see ~everyone (O(N^2) encode at the peak).
const RESPAWN_DELAY_TICKS := 150   # 5s @30Hz
const FIRE_CONE_DOT := 0.985       # broad-phase: target within ~10deg of ray
const FIRE_RANGE_MARGIN := 20.0    # grid broad-phase slack for lag-comp movement
const MAP_PATH := "res://maps/conquest_proving_grounds.json"
const MATCH_STATE_INTERVAL := 15   # ticks between match-state broadcasts (2 Hz)
const MATCH_END_DRAIN_TICKS := 60  # keep running ~2s after a win, then exit
const PIECES_PATH := "res://pieces/fortifications.json"

var _net: NetHost
var _port := 27015
var _start_tickets := -1
var _time_limit := -1.0
var _sim := SimLoop.new()
var _grid := InterestGrid.new(CELL_SIZE)
var _lag := LagComp.new()
var _tele := Telemetry.new()
var _map: MapDef
var _conquest: ConquestState
var _squads := SquadManager.new()
var _catalog: PieceCatalog
var _store: StructureStore
var _next_struct_id := 1
var _next_id := 1
var _tele_accum := 0.0
# Per-phase tick profiling (mean usec/tick over the telemetry window).
var _phase_us := {"poll": 0, "move": 0, "lag": 0, "interest": 0, "fire": 0, "respawn": 0, "conquest": 0, "match": 0, "snap": 0}
var _phase_ticks := 0
var _team_counts := {0: 0, 1: 0}
var _positions := {}               # id -> Vector3, rebuilt each tick before fires

var _kills := 0
var _shots := 0
var _hits := 0
var _rewind_clamped := 0
var _cap_events := 0          # per-telemetry-window (reset each second)
var _cap_events_total := 0    # cumulative over the match (for the match-end summary)
var _builds := 0
var _removes := 0
var _shots_blocked := 0
var _prev_owners: Array = []
var _match_over_broadcast := false
var _match_end_tick := -1

var _clients := {}
var _peer_to_id := {}

func configure(args: Dictionary) -> void:
	_port = int(args.get("port", _port))
	_start_tickets = int(args.get("tickets", -1))
	_time_limit = float(args.get("time-limit", -1.0))

func _ready() -> void:
	_map = MapDef.load_file(MAP_PATH)
	if _map == null:
		push_error("[server] failed to load map %s" % MAP_PATH); get_tree().quit(1); return
	_conquest = ConquestState.new(_map)
	if _start_tickets > 0:
		_conquest.tickets = [float(_start_tickets), float(_start_tickets)]
	if _time_limit > 0.0:
		_conquest.time_limit = _time_limit
	_prev_owners = _owner_snapshot()
	_catalog = PieceCatalog.load_file(PIECES_PATH)
	if _catalog == null:
		push_error("[server] failed to load pieces %s" % PIECES_PATH); get_tree().quit(1); return
	_store = StructureStore.new(_catalog)
	_sim.structures = _store
	_net = NetHost.new()
	add_child(_net)
	_net.peer_connected.connect(func(_p): pass)
	_net.peer_disconnected.connect(_on_peer_disconnected)
	_net.packet_received.connect(_on_packet)
	var err := _net.start_server(_port, MAX_PLAYERS)
	if err != OK:
		push_error("[server] bind failed on %d: %s" % [_port, error_string(err)]); get_tree().quit(1); return
	print("[server] listening on %d, tick=%dHz, max=%d map=%s" % [_port, TICK_RATE, MAX_PLAYERS, _map.name])

func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_net.poll()
	var t_poll := Time.get_ticks_usec()
	_step_movement()
	var t_move := Time.get_ticks_usec()
	_lag.record(_sim.tick, _sim.world)
	var t_lag := Time.get_ticks_usec()
	_build_interest()
	var t_int := Time.get_ticks_usec()
	_resolve_fires()
	var t_fire := Time.get_ticks_usec()
	_handle_respawns()
	var t_resp := Time.get_ticks_usec()
	_conquest.step(SimLoop.DT, _sim.world)
	var t_conq := Time.get_ticks_usec()
	_track_and_broadcast_match_state()
	var t_match := Time.get_ticks_usec()
	_send_snapshots()
	var t_snap := Time.get_ticks_usec()
	_phase_us["poll"] += t_poll - t0
	_phase_us["move"] += t_move - t_poll
	_phase_us["lag"] += t_lag - t_move
	_phase_us["interest"] += t_int - t_lag
	_phase_us["fire"] += t_fire - t_int
	_phase_us["respawn"] += t_resp - t_fire
	_phase_us["conquest"] += t_conq - t_resp
	_phase_us["match"] += t_match - t_conq
	_phase_us["snap"] += t_snap - t_match
	_phase_ticks += 1
	_tele.record_tick_ms(float(t_snap - t0) / 1000.0)
	_tele_accum += delta
	if _tele_accum >= 1.0:
		_log_telemetry(); _tele_accum = 0.0
	if _match_over_broadcast and _sim.tick >= _match_end_tick + MATCH_END_DRAIN_TICKS:
		print("[server] match complete, exiting"); get_tree().quit(0)

func _build_interest() -> void:
	# Built once per tick here so the grid/_positions are reused by BOTH the fire
	# broad-phase (_resolve_fires) and snapshots (_send_snapshots). Consequence: a pawn
	# that respawns later this tick (_handle_respawns) has one-tick-stale interest-set
	# membership in snapshots — its position DATA via state_map() is still fresh; only
	# which interest sets it falls into lags by a tick. Accepted to keep the grid
	# single-build per tick (the perf goal); self-corrects next tick.
	_positions.clear()
	_grid.clear()
	for id in _sim.world.pawns:
		var p: Pawn = _sim.world.pawns[id]
		_positions[id] = p.pos
		_grid.insert(id, p.pos)

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
		_shots += 1
		_fire_shot(id, shooter, inp, shot_index)

func _fire_shot(shooter_id: int, shooter: Pawn, inp: Dictionary, shot_index: int) -> void:
	var lean_sign := 0
	if shooter.lean == Stance.LEAN_LEFT: lean_sign = -1
	elif shooter.lean == Stance.LEAN_RIGHT: lean_sign = 1
	var moving: bool = absf(inp["move_x"]) + absf(inp["move_y"]) > 0.01
	var wid: int = _clients[shooter_id]["weapon"]
	var ray := Combat.reconstruct_ray(wid, shooter.eye_position(),
		inp["yaw"], inp["pitch"], lean_sign, shooter_id, _sim.tick, shot_index, moving)

	var view_tick: int = inp["view_server_tick"]
	if view_tick < _sim.tick - LagComp.MAX_REWIND or view_tick > _sim.tick:
		_rewind_clamped += 1
	var frame := _lag.rewind(view_tick)

	var max_range: float = Weapon.get_def(wid)["range_m"]
	# Broad-phase: only candidates near the shooter (current positions + lag-comp margin),
	# instead of scanning the whole rewound frame. Objective clustering raises density, so
	# this keeps per-shot cost bounded. Precise test still uses the rewound state.
	var candidates: Array = _grid.query(shooter.pos, max_range + FIRE_RANGE_MARGIN, _positions)
	var best_t := max_range + 1.0
	var best_victim := 0
	var best_head := false
	for tid in candidates:
		if tid == shooter_id: continue
		if not frame.has(tid): continue
		var st = frame[tid]
		if not st["alive"] or st["team"] == shooter.team: continue
		var to_target: Vector3 = st["pos"] - ray["origin"]
		if to_target.length() > max_range: continue
		if to_target.normalized().dot(ray["dir"]) < FIRE_CONE_DOT: continue
		var hit := Hitbox.raycast_pawn(ray["origin"], ray["dir"], st["pos"], st["stance"], max_range)
		if hit["hit"] and hit["t"] < best_t:
			best_t = hit["t"]; best_victim = tid; best_head = hit["headshot"]
	# Cover: a structure between shooter and target absorbs the shot (Phase 1: no piece damage).
	var blocked := _store.march(ray["origin"], ray["dir"], max_range)
	var block_dist: float = blocked["dist"] if blocked["hit"] else INF
	if best_victim == 0 or block_dist < best_t:
		if blocked["hit"]:
			_shots_blocked += 1
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
		_conquest.register_death(victim.team)
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
			p.pos = _select_spawn(id)
			p.velocity = Vector3.ZERO
			p.health = 100
			p.alive = true
			p.stamina = Pawn.STAMINA_MAX
			c["respawn_tick"] = 0
			c["ammo"] = Weapon.get_def(c["weapon"])["mag_size"]
			c["reloading"] = false

func _select_spawn(id: int) -> Vector3:
	var c = _clients[id]
	var team: int = c["team"]
	var obj := _objective_for(team)
	var mates: Array = []
	for mid in _squads.members(team, c["squad"]):
		if mid == id: continue
		var mp: Pawn = _sim.world.get_pawn(mid)
		if mp != null and mp.alive: mates.append(mp.pos)
	return SpawnSelect.select(team, _map, _conquest, mates, obj)

func _objective_for(team: int) -> Vector3:
	var base := _map.base_for(team)
	var from: Vector3 = base["pos"] if not base.is_empty() else Vector3.ZERO
	var idx := _conquest.nearest_capturable_index(team, from)
	return _conquest.points[idx]["pos"] if idx >= 0 else from

func _owner_snapshot() -> Array:
	var a: Array = []
	for pt in _conquest.points: a.append(pt["owner"])
	return a

func _track_and_broadcast_match_state() -> void:
	var owners := _owner_snapshot()
	for i in owners.size():
		if i < _prev_owners.size() and owners[i] != _prev_owners[i]:
			_cap_events += 1
			_cap_events_total += 1
	_prev_owners = owners
	if _conquest.match_over and not _match_over_broadcast:
		_match_over_broadcast = true
		_match_end_tick = _sim.tick
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], true, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)
		print("[match] OVER winner=%d t0=%d t1=%d elapsed=%ds cap_events=%d"
			% [_conquest.winner, _conquest.tickets_int(0), _conquest.tickets_int(1), int(_conquest.elapsed), _cap_events_total])
	elif not _match_over_broadcast and _sim.tick % MATCH_STATE_INTERVAL == 0:
		var bytes := Protocol.encode_match_state(_conquest.points,
			[_conquest.tickets_int(0), _conquest.tickets_int(1)], false, _conquest.winner, int(_conquest.elapsed))
		for cid in _clients:
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_SNAPSHOT, bytes, 0)

func _send_snapshots() -> void:
	var state := _sim.world.state_map()
	for id in _clients:
		# Stagger sends across ticks so the per-tick snapshot encode cost (the dominant tick
		# cost at high player counts) is ~clients/SNAPSHOT_STRIDE rather than O(clients).
		if (_sim.tick + id) % SNAPSHOT_STRIDE != 0:
			continue
		var c = _clients[id]
		var self_pawn = _sim.world.get_pawn(id)
		if self_pawn == null: continue
		var ids := _grid.query(self_pawn.pos, INTEREST_RADIUS, _positions)
		if ids.size() > MAX_SNAPSHOT_ENTITIES:
			# Relevance cull to the cap, prioritising ENEMIES (a player must see nearby foes
			# even inside a crowd of teammates — pure nearest-N would hide them) and always
			# keeping self (needed for reconciliation). Enemies first by distance, then the
			# nearest teammates fill the rest. Only paid when over the cap (dense clusters).
			var sp: Vector3 = self_pawn.pos
			var myteam: int = self_pawn.team
			var ranked: Array = []
			ranked.resize(ids.size())
			for i in ids.size():
				var vid: int = ids[i]
				var key: float = sp.distance_squared_to(_positions[vid])
				if int(state[vid].team) == myteam:
					key += 1.0e15   # teammates rank after every enemy
				ranked[i] = [key, vid]
			ranked.sort()
			var kept := {id: true}
			for pair in ranked:
				if kept.size() >= MAX_SNAPSHOT_ENTITIES:
					break
				kept[pair[1]] = true
			ids = kept.keys()
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
		Protocol.Msg.BUILD_REQUEST: _handle_build_request(peer, bytes)
		Protocol.Msg.BUILD_REMOVE: _handle_build_remove(peer, bytes)
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
	var squad := _squads.assign(id, team)
	_peer_to_id[peer] = id
	_clients[id] = {
		"peer": peer, "queued_input": null, "last_input": null, "last_input_tick": 0,
		"last_acked_seq": 0, "next_seq": 1, "history": {},
		"team": team, "squad": squad, "class": cls, "weapon": wid, "ammo": Weapon.get_def(wid)["mag_size"],
		"reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "respawn_tick": 0,
		"last_build_tick": -100000, "known_regions": {},
	}
	var p := _sim.world.spawn(id)
	p.team = team
	p.squad = squad
	p.pos = _select_spawn(id)
	_net.send_to(peer, NetHost.CHANNEL_CONTROL, Protocol.encode_welcome(id, TICK_RATE), ENetPacketPeer.FLAG_RELIABLE)
	print("[server] welcomed peer %d ('%s') team=%d squad=%d class=%d — %d peers" % [id, pname, team, squad, cls, _clients.size()])

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

func _handle_build_request(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var c = _clients[id]
	var p: Pawn = _sim.world.get_pawn(id)
	if p == null or not p.alive: return
	var d := Protocol.decode_build_request(bytes)
	var type: int = d["type"]
	if type < 0 or type >= _catalog.size(): return
	var cell: Vector3i = d["cell"]
	var v := _store.validate_place(cell, p.pos, _sim.tick, c["last_build_tick"], Pawn.WORLD_HALF)
	if not v["ok"]: return
	if _store.owner_count(id) >= StructureStore.MAX_PIECES_PER_PLAYER:
		var old_id := _store.oldest_id(id)
		if old_id != 0:
			var old_cell := _cell_of_struct(old_id)   # capture BEFORE removal (record still present)
			_store.recycle_oldest(id)
			_removes += 1
			_emit_structure_delta(Protocol.OP_REMOVE, {"id": old_id}, old_cell)
	var sid := _next_struct_id
	_next_struct_id += 1
	var rec := _store.place(sid, type, cell, d["yaw"], id)
	if rec.is_empty(): return   # lost a race for the cell
	c["last_build_tick"] = _sim.tick
	_builds += 1
	_emit_structure_delta(Protocol.OP_PLACE, rec, cell)

func _handle_build_remove(peer: ENetPacketPeer, bytes: PackedByteArray) -> void:
	var id = _peer_to_id.get(peer, 0)
	if id == 0 or not _clients.has(id): return
	var rid: int = Protocol.decode_build_remove(bytes)["id"]
	var rec := _store.get_record(rid)
	if rec.is_empty() or int(rec["owner"]) != id: return
	var cell: Vector3i = rec["cell"]
	_store.remove(rid)
	_removes += 1
	_emit_structure_delta(Protocol.OP_REMOVE, {"id": rid}, cell)

## Cell of a still-present record (for remove-delta routing). Returns a far cell if gone.
func _cell_of_struct(id: int) -> Vector3i:
	var rec := _store.get_record(id)
	return rec["cell"] if not rec.is_empty() else Vector3i(0, 0, 0)

## Send a structure delta to every client whose current interest region covers the cell's region.
func _emit_structure_delta(op: int, rec: Dictionary, cell: Vector3i) -> void:
	var region := _store.region_of(cell)
	var bytes := Protocol.encode_structure_delta(op, rec)
	for cid in _clients:
		if _clients[cid]["known_regions"].has(region):
			_net.send_to(_clients[cid]["peer"], NetHost.CHANNEL_CONTROL, bytes, ENetPacketPeer.FLAG_RELIABLE)

func _on_peer_disconnected(peer: ENetPacketPeer) -> void:
	var id = _peer_to_id.get(peer, 0)
	_peer_to_id.erase(peer)
	if id != 0 and _clients.has(id):
		var team: int = _clients[id]["team"]
		_team_counts[team] -= 1
		_squads.remove(id, team)
		_clients.erase(id)
		_sim.world.despawn(id)
		print("[server] peer %d disconnected — %d peers" % [id, _clients.size()])

func _log_telemetry() -> void:
	var n := _clients.size()
	var alive := 0
	for id in _sim.world.pawns:
		if _sim.world.pawns[id].alive: alive += 1
	var mbit := float(_tele.total_bytes()) * 8.0 / 1_000_000.0
	var hit_rate := 0.0 if _shots == 0 else float(_hits) / float(_shots)
	var pts := ""
	for pt in _conquest.points:
		pts += "." if pt["owner"] == -1 else str(pt["owner"])
	print("[telemetry] players=%d alive=%d tick_mean=%.2fms tick_p99=%.2fms agg=%.1fMbit/s kills=%d shots=%d hit_rate=%.2f starv=%d rewind_clamped=%d t0=%d t1=%d pts=%s cap_events=%d"
		% [n, alive, _tele.mean_tick_ms(), _tele.p99_tick_ms(), mbit, _kills, _shots, hit_rate, _tele.starvation, _rewind_clamped, _conquest.tickets_int(0), _conquest.tickets_int(1), pts, _cap_events])
	var pt := maxi(_phase_ticks, 1)
	print("[perf] us/tick: poll=%d move=%d lag=%d interest=%d fire=%d respawn=%d conquest=%d match=%d snap=%d (ticks=%d)"
		% [_phase_us["poll"] / pt, _phase_us["move"] / pt, _phase_us["lag"] / pt, _phase_us["interest"] / pt, _phase_us["fire"] / pt, _phase_us["respawn"] / pt, _phase_us["conquest"] / pt, _phase_us["match"] / pt, _phase_us["snap"] / pt, _phase_ticks])
	for k in _phase_us: _phase_us[k] = 0
	_phase_ticks = 0
	_tele.reset_window()
	_kills = 0; _shots = 0; _hits = 0; _rewind_clamped = 0; _cap_events = 0
