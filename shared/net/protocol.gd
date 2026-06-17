class_name Protocol
extends Object
## Wire protocol message (de)serialization. The single source of truth for the
## byte layout used by client, server, and bot driver. This file is the reason
## the three roles can never disagree about the protocol — they all encode/decode
## through here. See docs/AGENTS.md §7.
##
## M0 covers only the connection handshake. M1 extends this with input command
## frames and delta-compressed snapshots (see docs/specs/wire-protocol.md).

const VERSION := 1

enum Msg {
	HELLO = 1,    ## client -> server: protocol version + display name
	WELCOME = 2,  ## server -> client: assigned peer id + server tick rate
	REJECT = 3,   ## server -> client: rejection reason (then disconnect)
	INPUT = 4,    ## client -> server: input command frame (see input_command.gd)
	SNAPSHOT = 5, ## server -> client: delta snapshot (see snapshot.gd)
	KILL = 6,     ## server -> clients: kill event (victim, killer, weapon, headshot)
	MATCH_STATE = 7, ## server -> clients: conquest state (point owners/cap, tickets, win)
	BUILD_REQUEST = 8,      ## client -> server: place a fortification piece
	BUILD_REMOVE = 9,       ## client -> server: remove an owned piece by id
	STRUCTURE_DELTA = 10,   ## server -> clients: piece placed/removed (event-based)
	STRUCTURE_BASELINE = 11,## server -> client: all pieces in a region (on interest entry)
	GRENADE_THROW = 12,     ## client -> server: throw a grenade (type FRAG/SMOKE) in a look dir
	# DETONATION = 13       ## RESERVED (M7 frag VFX); not sent in the M4-P2 gate
	SMOKE_DEPLOYED = 14,    ## server -> clients: a smoke zone was created (pos/radius/expire)
	REVIVE_ACTION = 15,     ## client -> server: begin/continue (active) or stop reviving a downed teammate
	SELF_BANDAGE = 16,      ## client -> server: use a bandage on self to halt bleed
	GADGET_ACTION = 17, ## client -> server: gadget intent (C4/mine/RPG/bag/active-give); action byte selects
	VEHICLE_ACTION = 18,    ## client -> server: enter/exit a vehicle seat
	VEHICLE_DESTROYED = 19, ## server -> clients: a vehicle was destroyed (vid)
	DEPLOY_REQUEST = 20,    ## client -> server: deploy me at spawn_ref (see DeploySpawn)
	DAMAGE_EVENT = 21,      ## server -> client: damage taken, world bearing toward source + amount
	SELF_STATE = 22,        ## server -> owning client: authoritative weapon state for ammo reconcile
	HITMARKER = 23,         ## server -> shooter: your shot hit an enemy (headshot/lethal flags)
	GIVE_UP = 24,           ## client -> server: while DOWNED, skip the bleed-out and die now
}

const OP_PLACE := 0
const OP_REMOVE := 1
const OP_DAMAGE := 2   ## STRUCTURE_DELTA payload {id u16, bucket u8} — partial-health bucket drop

# GADGET_ACTION sub-actions.
const GA_C4_PLACE := 0
const GA_C4_DETONATE := 1
const GA_MINE_PLACE := 2
const GA_RPG_FIRE := 3
const GA_BAG_THROW := 4
const GA_GIVE_START := 5
const GA_GIVE_STOP := 6
const GA_REPAIR_START := 7
const GA_REPAIR_STOP := 8

# VEHICLE_ACTION sub-actions.
const VA_ENTER := 0
const VA_EXIT := 1


static func encode_hello(player_name: String, auto_deploy: bool = true) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.HELLO)
	buf.put_u16(VERSION)
	buf.put_utf8_string(player_name)
	buf.put_u8(1 if auto_deploy else 0)
	return buf.data_array


static func encode_welcome(peer_id: int, tick_rate: int, cls: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.WELCOME)
	buf.put_u32(peer_id)
	buf.put_u16(tick_rate)
	buf.put_u8(cls)
	return buf.data_array


static func decode_welcome(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"id": r.get_u32(), "tick_rate": r.get_u16(), "class": r.get_u8()}


static func encode_reject(reason: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REJECT)
	buf.put_utf8_string(reason)
	return buf.data_array


## Type byte of a message (0 if empty).
static func msg_type(bytes: PackedByteArray) -> int:
	return bytes[0] if not bytes.is_empty() else 0


## Returns a buffer seeked past the 1-byte type, ready to read the body fields.
static func body_reader(bytes: PackedByteArray) -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)
	return buf


static func encode_kill(victim_id: int, killer_id: int, weapon_id: int, headshot: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.KILL)
	buf.put_u32(victim_id)
	buf.put_u32(killer_id)
	buf.put_u8(weapon_id)
	buf.put_u8(1 if headshot else 0)
	return buf.data_array


static func decode_kill(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"victim": r.get_u32(), "killer": r.get_u32(), "weapon": r.get_u8(), "headshot": r.get_u8() == 1}


static func encode_hitmarker(headshot: bool, lethal: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.HITMARKER)
	buf.put_u8((1 if headshot else 0) | (2 if lethal else 0))
	return buf.data_array


static func decode_hitmarker(bytes: PackedByteArray) -> Dictionary:
	var f := body_reader(bytes).get_u8()
	return {"headshot": (f & 1) != 0, "lethal": (f & 2) != 0}


static func encode_give_up() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GIVE_UP)
	return buf.data_array


static func encode_match_state(points: Array, tickets: Array, match_over: bool, winner: int, elapsed: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.MATCH_STATE)
	buf.put_u8(points.size())
	for pt in points:
		buf.put_8(int(pt["owner"]))
		buf.put_8(int(pt["attacker"]))
		buf.put_u8(clampi(roundi(float(pt["cap"]) * 255.0), 0, 255))
	buf.put_u16(clampi(int(tickets[0]), 0, 65535))
	buf.put_u16(clampi(int(tickets[1]), 0, 65535))
	buf.put_u8(1 if match_over else 0)
	buf.put_8(winner)
	buf.put_u16(clampi(elapsed, 0, 65535))
	return buf.data_array


static func decode_match_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var pts := []
	for i in n:
		pts.append({"owner": r.get_8(), "attacker": r.get_8(), "cap": float(r.get_u8()) / 255.0})
	var t0 := r.get_u16()
	var t1 := r.get_u16()
	var over := r.get_u8() == 1
	var win := r.get_8()
	var el := r.get_u16()
	return {"points": pts, "tickets": [t0, t1], "match_over": over, "winner": win, "elapsed": el}


static func encode_build_request(type: int, cell: Vector3i, yaw: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BUILD_REQUEST)
	buf.put_u8(type)
	buf.put_16(cell.x); buf.put_16(cell.y); buf.put_16(cell.z)
	buf.put_u8(yaw)
	return buf.data_array


static func decode_build_request(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var type := r.get_u8()
	var cell := Vector3i(r.get_16(), r.get_16(), r.get_16())
	return {"type": type, "cell": cell, "yaw": r.get_u8()}


static func encode_build_remove(id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BUILD_REMOVE)
	buf.put_u16(id)
	return buf.data_array


static func decode_build_remove(bytes: PackedByteArray) -> Dictionary:
	return {"id": body_reader(bytes).get_u16()}


static func _put_record(buf: StreamPeerBuffer, rec: Dictionary) -> void:
	buf.put_u8(int(rec["type"]))
	buf.put_u16(int(rec["id"]))
	var cell: Vector3i = rec["cell"]
	buf.put_16(cell.x); buf.put_16(cell.y); buf.put_16(cell.z)
	buf.put_u8(int(rec["yaw"]))
	buf.put_u16(int(rec["health"]))
	buf.put_u16(int(rec["owner"]))


static func _get_record(r: StreamPeerBuffer) -> Dictionary:
	var type := r.get_u8()
	var id := r.get_u16()
	var cell := Vector3i(r.get_16(), r.get_16(), r.get_16())
	var yaw := r.get_u8()
	var health := r.get_u16()
	var owner := r.get_u16()
	return {"id": id, "type": type, "cell": cell, "yaw": yaw, "health": health, "owner": owner}


static func encode_structure_delta(op: int, rec: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_DELTA)
	buf.put_u8(op)
	if op == OP_PLACE:
		_put_record(buf, rec)
	elif op == OP_DAMAGE:
		buf.put_u16(int(rec["id"]))
		buf.put_u8(int(rec["bucket"]))
	else:
		buf.put_u16(int(rec["id"]))
	return buf.data_array


static func decode_structure_delta(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var op := r.get_u8()
	if op == OP_PLACE:
		return {"op": op, "rec": _get_record(r)}
	elif op == OP_DAMAGE:
		var id := r.get_u16()
		return {"op": op, "id": id, "bucket": r.get_u8()}
	return {"op": op, "id": r.get_u16()}


static func encode_grenade_throw(dir: Vector3, type: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GRENADE_THROW)
	var d := dir.normalized()
	buf.put_16(roundi(d.x * 10000.0))
	buf.put_16(roundi(d.y * 10000.0))
	buf.put_16(roundi(d.z * 10000.0))
	buf.put_u8(type)
	return buf.data_array


static func decode_grenade_throw(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var x := float(r.get_16()) / 10000.0
	var y := float(r.get_16()) / 10000.0
	var z := float(r.get_16()) / 10000.0
	return {"dir": Vector3(x, y, z), "type": r.get_u8()}


static func encode_smoke_deployed(pos: Vector3, radius: float, expire_tick: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SMOKE_DEPLOYED)
	buf.put_16(roundi(pos.x)); buf.put_16(roundi(pos.y)); buf.put_16(roundi(pos.z))
	buf.put_u8(clampi(roundi(radius), 0, 255))
	buf.put_u16(clampi(expire_tick, 0, 65535))   # absolute tick (u16); fine for gate-length matches
	return buf.data_array


static func decode_smoke_deployed(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var pos := Vector3(r.get_16(), r.get_16(), r.get_16())
	return {"pos": pos, "radius": r.get_u8(), "expire_tick": r.get_u16()}


static func encode_revive_action(target_id: int, active: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REVIVE_ACTION)
	buf.put_u32(target_id)
	buf.put_u8(1 if active else 0)
	return buf.data_array


static func decode_revive_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"target": r.get_u32(), "active": r.get_u8() == 1}


static func encode_self_bandage() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_BANDAGE)
	return buf.data_array


static func encode_gadget_action(action: int, pos: Vector3, dir: Vector3, target_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GADGET_ACTION)
	buf.put_u8(action)
	# pos quantized at 0.1 m (i16 ×10 → ±3276 m, covers the ±1000 m world_half; spec sketch)
	buf.put_16(roundi(pos.x * 10.0)); buf.put_16(roundi(pos.y * 10.0)); buf.put_16(roundi(pos.z * 10.0))
	var dn := dir.normalized() if dir.length() > 0.0001 else Vector3.ZERO
	buf.put_16(roundi(dn.x * 10000.0)); buf.put_16(roundi(dn.y * 10000.0)); buf.put_16(roundi(dn.z * 10000.0))
	buf.put_u32(target_id)
	return buf.data_array


static func decode_gadget_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var action := r.get_u8()
	var pos := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	var dir := Vector3(float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0)
	return {"action": action, "pos": pos, "dir": dir, "target": r.get_u32()}


static func encode_structure_baseline(region: Vector2i, records: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_BASELINE)
	buf.put_32(region.x); buf.put_32(region.y)
	buf.put_u16(records.size())
	for rec in records:
		_put_record(buf, rec)
	return buf.data_array


static func decode_structure_baseline(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var region := Vector2i(r.get_32(), r.get_32())
	var n := r.get_u16()
	var records: Array = []
	for _i in n:
		records.append(_get_record(r))
	return {"region": region, "records": records}


static func encode_vehicle_action(action: int, vehicle_id: int, seat_hint: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.VEHICLE_ACTION)
	buf.put_u8(action); buf.put_u32(vehicle_id); buf.put_u8(seat_hint)
	return buf.data_array

static func decode_vehicle_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"action": r.get_u8(), "vehicle_id": r.get_u32(), "seat_hint": r.get_u8()}

static func encode_vehicle_destroyed(vehicle_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.VEHICLE_DESTROYED)
	buf.put_u32(vehicle_id)
	return buf.data_array

static func decode_vehicle_destroyed(bytes: PackedByteArray) -> Dictionary:
	return {"vehicle_id": body_reader(bytes).get_u32()}


static func encode_deploy_request(spawn_ref: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DEPLOY_REQUEST)
	buf.put_u8(spawn_ref & 0xFF)
	return buf.data_array

static func decode_deploy_request(bytes: PackedByteArray) -> Dictionary:
	return {"spawn_ref": body_reader(bytes).get_u8()}


static func encode_damage_event(bearing: float, amount: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DAMAGE_EVENT)
	buf.put_u16(Quantize.enc_angle(bearing))
	buf.put_u8(clampi(amount, 0, 255))
	return buf.data_array

static func decode_damage_event(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"bearing": Quantize.dec_angle(r.get_u16()), "amount": r.get_u8()}


static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_STATE)
	buf.put_u8(clampi(mag, 0, 255))
	buf.put_u8(1 if reloading else 0)
	buf.put_u16(clampi(reload_remaining, 0, 65535))
	buf.put_u8(weapon & 0xFF)
	return buf.data_array

static func decode_self_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"mag": r.get_u8(), "reloading": r.get_u8() == 1, "reload_remaining": r.get_u16(), "weapon": r.get_u8()}
