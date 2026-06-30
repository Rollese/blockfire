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
	DETONATION = 13,        ## server -> human clients: a grenade detonated at pos (cosmetic explosion VFX, M7)
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
	ROSTER = 25,            ## server -> clients: per-client name/team/squad/kills/deaths/score
	SET_SQUAD = 26,         ## client -> server: join/switch to squad id
	DEATH_INFO = 27,        ## server -> victim: death-recap (killer/weapon/distance/hp + per-attacker damage)
	SHOT_FX = 28,           ## server -> human clients: cosmetic tracer for a remote pawn's shot (origin+dir)
	COLLAPSE = 29,          ## server -> clients: a building fully collapsed (building_id) -> rubble swap
	ROCKET_FX = 30,         ## server -> human clients: an RPG rocket was launched (origin+dir) -> cosmetic flying rocket
	SET_FIRE_MODE = 31,     ## client -> server: select fire mode (AUTO/SEMI/BURST) for current weapon
	SWAP_WEAPON = 32,       ## client -> server: quick-swap to weapon slot (0=primary, 1=secondary)
	MELEE = 33,             ## client -> server: melee swing (knife / Engineer sledgehammer); zero payload
	IMPACT_FX = 34,         ## server -> human clients: a bullet hit world geometry at pos (cosmetic impact puff)
	GRENADE_FX = 35,        ## server -> human clients: a remote pawn threw a grenade (cosmetic arcing object)
	GADGET_LIST = 36,       ## server -> human clients: authoritative list of deployed gadgets (C4/mine/bag) to render
	SUPPORT_LIST = 37,      ## server -> human clients: active support links (heal/ammo/repair/revive) -> beam + aura
	PLACE_FOB = 38,         ## client -> server: squad leader requests a FOB build site at a cell
	REMOVE_FOB = 39,        ## client -> server: squad leader removes their squad's FOB (site or built)
	FOB_LIST = 40,          ## server -> human clients: their team's FOBs {squad, structure_id, uc, enabled}
	RELOAD_FX = 41,         ## server -> human clients: a remote pawn started reloading (id + duration) -> reload pose
}

const OP_PLACE := 0
const OP_REMOVE := 1
const OP_CHUNK := 2   ## STRUCTURE_DELTA payload {id u16, mask u64} — sub-cell alive-mask (M11)
const OP_PROGRESS := 3   ## STRUCTURE_DELTA payload {id u16, progress u16} — build-site progress tick (M12-P2)

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


static func encode_welcome(peer_id: int, tick_rate: int, cls: int = 0, map_name: String = "") -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.WELCOME)
	buf.put_u32(peer_id)
	buf.put_u16(tick_rate)
	buf.put_u8(cls)
	buf.put_utf8_string(map_name)   # server-authoritative map basename so the client loads the right one
	return buf.data_array


static func decode_welcome(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var id := r.get_u32()
	var tick_rate := r.get_u16()
	var cls := r.get_u8()
	# Map name is a trailing field — guard so a legacy welcome without it still decodes.
	var map_name := r.get_utf8_string() if r.get_available_bytes() > 0 else ""
	return {"id": id, "tick_rate": tick_rate, "class": cls, "map": map_name}


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
	buf.put_u64(int(rec["chunks"]))
	buf.put_u16(int(rec["building_id"]))
	buf.put_u16(int(rec["owner"]))
	buf.put_u8(int(rec.get("under_construction", 0)))                       # M12-P2
	buf.put_u16(clampi(int(rec.get("build_progress", 0)), 0, 65535))        # M12-P2


static func _get_record(r: StreamPeerBuffer) -> Dictionary:
	var type := r.get_u8()
	var id := r.get_u16()
	var cell := Vector3i(r.get_16(), r.get_16(), r.get_16())
	var yaw := r.get_u8()
	var chunks := r.get_u64()
	var building_id := r.get_u16()
	var owner := r.get_u16()
	var uc := r.get_u8() if r.get_available_bytes() > 0 else 0
	var prog := r.get_u16() if r.get_available_bytes() > 0 else 0
	return {"id": id, "type": type, "cell": cell, "yaw": yaw, "chunks": chunks, "building_id": building_id, "owner": owner, "under_construction": uc, "build_progress": prog}


static func encode_structure_delta(op: int, rec: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_DELTA)
	buf.put_u8(op)
	if op == OP_PLACE:
		_put_record(buf, rec)
	elif op == OP_CHUNK:
		buf.put_u16(int(rec["id"]))
		buf.put_u64(int(rec["mask"]))
	else:
		buf.put_u16(int(rec["id"]))
	return buf.data_array


static func decode_structure_delta(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var op := r.get_u8()
	if op == OP_PLACE:
		return {"op": op, "rec": _get_record(r)}
	elif op == OP_CHUNK:
		var id := r.get_u16()
		return {"op": op, "id": id, "mask": r.get_u64()}
	elif op == OP_PROGRESS:
		var id := r.get_u16()
		return {"op": op, "id": id, "progress": r.get_u16()}
	return {"op": op, "id": r.get_u16()}


static func encode_structure_progress(id: int, progress: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.STRUCTURE_DELTA)
	buf.put_u8(OP_PROGRESS)
	buf.put_u16(id)
	buf.put_u16(clampi(progress, 0, 65535))
	return buf.data_array


static func encode_collapse(building_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.COLLAPSE)
	buf.put_u16(building_id)
	return buf.data_array

static func decode_collapse(bytes: PackedByteArray) -> int:
	return body_reader(bytes).get_u16()


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


## Cosmetic remote-shot tracer: muzzle origin (0.1 m units) + aim direction (unit vec, 1e-4 units).
## Best-effort/unreliable; presentation-only (no gameplay effect). Mirrors the gadget pos/dir packing.
# Detonation VFX kind (which cosmetic effect the client spawns).
const DET_EXPLOSION := 0   # frag / impact — orange blast + debris + smoke puff
const DET_FLASH := 1       # flashbang — bright white pop

## Grenade detonation (M7 cosmetic): position (×10 = 0.1 m) + a vfx-kind byte. Server -> human clients.
static func encode_detonation(pos: Vector3, kind: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DETONATION)
	buf.put_16(clampi(roundi(pos.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(pos.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(pos.z * 10.0), -32768, 32767))
	buf.put_u8(kind & 0xFF)
	return buf.data_array


static func decode_detonation(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var pos := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	return {"pos": pos, "kind": r.get_u8()}


static func encode_shot_fx(origin: Vector3, dir: Vector3, shooter_id: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SHOT_FX)
	buf.put_16(clampi(roundi(origin.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.z * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.x * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.y * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.z * 10000.0), -32768, 32767))
	buf.put_u32(shooter_id)   # bind the FX to the firing pawn (remote fire-recoil pose)
	return buf.data_array


static func decode_shot_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var origin := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	var dir := Vector3(float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0)
	var shooter_id := r.get_u32() if r.get_available_bytes() > 0 else 0   # trailing, backward-compatible
	return {"origin": origin, "dir": dir, "shooter_id": shooter_id}

## Remote reload cue — a remote pawn began reloading. id + how long (ticks) the reload runs so the
## client can hold a reload pose for the right duration. View-only; sent only to human clients.
static func encode_reload_fx(reloader_id: int, duration_ticks: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.RELOAD_FX)
	buf.put_u32(reloader_id)
	buf.put_u16(clampi(duration_ticks, 0, 65535))
	return buf.data_array

static func decode_reload_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"reloader_id": r.get_u32(), "duration_ticks": r.get_u16()}

## RPG rocket launch — same wire shape as SHOT_FX (origin ×10, unit dir ×10000); the client rebuilds
## the velocity from the known rocket speed and flies a cosmetic projectile along the ballistic arc.
static func encode_rocket_fx(origin: Vector3, dir: Vector3) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.ROCKET_FX)
	buf.put_16(clampi(roundi(origin.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.z * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.x * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.y * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.z * 10000.0), -32768, 32767))
	return buf.data_array

static func decode_rocket_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var origin := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	var dir := Vector3(float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0)
	return {"origin": origin, "dir": dir}

## Remote thrown grenade — same wire shape as ROCKET_FX (origin ×10, look dir ×10000) plus a kind
## byte (Grenade.FRAG/SMOKE); the client rebuilds the launch velocity and arcs a cosmetic grenade.
static func encode_grenade_fx(origin: Vector3, dir: Vector3, kind: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GRENADE_FX)
	buf.put_16(clampi(roundi(origin.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(origin.z * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.x * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.y * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(dir.z * 10000.0), -32768, 32767))
	buf.put_u8(clampi(kind, 0, 255))
	return buf.data_array

static func decode_grenade_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var origin := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	var dir := Vector3(float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0)
	return {"origin": origin, "dir": dir, "kind": r.get_u8()}

## Authoritative deployed-gadget list — each entry: kind byte (GadgetList.C4/MINE/BAG), pos ×10,
## facing x/z ×10000 (zero for C4/bags). The client replaces its rendered gadget set on each receipt.
static func encode_gadget_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GADGET_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var g: Dictionary = list[i]
		var pos: Vector3 = g["pos"]
		var face: Vector3 = g.get("face", Vector3.ZERO)
		buf.put_u8(clampi(int(g["kind"]), 0, 255))
		buf.put_16(clampi(roundi(pos.x * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(pos.y * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(pos.z * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(face.x * 10000.0), -32768, 32767))
		buf.put_16(clampi(roundi(face.z * 10000.0), -32768, 32767))
	return buf.data_array

static func decode_gadget_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var kind := r.get_u8()
		var pos := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
		var face := Vector3(float(r.get_16()) / 10000.0, 0.0, float(r.get_16()) / 10000.0)
		out.append({"kind": kind, "pos": pos, "face": face})
	return out

## Active support links (M7): each entry is giver_id u32 + target_id u32 + kind u8
## (SupportLinks.HEAL/AMMO/REPAIR/REVIVE). No coordinates on the wire — the client resolves both
## endpoints from its own snapshot (pawn or vehicle ids it already mirrors) and skips any it can't
## see. Rebuilt + sent each tick like GADGET_LIST; view-only.
static func encode_support_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SUPPORT_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var e: Dictionary = list[i]
		buf.put_u32(int(e["giver"]))
		buf.put_u32(int(e["target"]))
		buf.put_u8(clampi(int(e["kind"]), 0, 255))
	return buf.data_array

static func decode_support_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var giver := r.get_u32()
		var target := r.get_u32()
		var kind := r.get_u8()
		out.append({"giver": giver, "target": target, "kind": kind})
	return out

# Bullet impact VFX kind (which cosmetic puff the client spawns at the hit point).
const IMPACT_WALL := 0   # bullet stopped on (or punched through) a structure / wall — grey dust + chips
const IMPACT_DIRT := 1   # bullet hit the ground — brown dirt
const IMPACT_FLESH := 2  # bullet hit a pawn — red blood mist puff

## Cosmetic bullet impact (M7): hit position (×10 = 0.1 m) + a surface-kind byte. Server -> human
## clients, best-effort/unreliable; presentation-only (no gameplay effect).
static func encode_impact_fx(pos: Vector3, kind: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.IMPACT_FX)
	buf.put_16(clampi(roundi(pos.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(pos.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(pos.z * 10.0), -32768, 32767))
	buf.put_u8(kind)
	return buf.data_array

static func decode_impact_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var pos := Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)
	var kind := r.get_u8()
	return {"pos": pos, "kind": kind}


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
	buf.put_u16(spawn_ref & 0xFFFF)   # u16: squadmate(200+pawn_id)/vehicle(400+slot) refs exceed 255
	return buf.data_array

static func decode_deploy_request(bytes: PackedByteArray) -> Dictionary:
	return {"spawn_ref": body_reader(bytes).get_u16()}


static func encode_damage_event(bearing: float, amount: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DAMAGE_EVENT)
	buf.put_u16(Quantize.enc_angle(bearing))
	buf.put_u8(clampi(amount, 0, 255))
	return buf.data_array

static func decode_damage_event(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"bearing": Quantize.dec_angle(r.get_u16()), "amount": r.get_u8()}


static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int, throwables: Array = [], being_revived: bool = false, suppression: float = 0.0, blind_ticks: int = 0, bandage_count: int = 0, bleed_halted: bool = false) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_STATE)
	buf.put_u8(clampi(mag, 0, 255))
	buf.put_u8(1 if reloading else 0)
	buf.put_u16(clampi(reload_remaining, 0, 65535))
	buf.put_u8(weapon & 0xFF)
	buf.put_u8(1 if being_revived else 0)   # downed-screen "a teammate is reviving you" indicator
	buf.put_u8(mini(throwables.size(), 255))
	for i in mini(throwables.size(), 255):
		var t: Dictionary = throwables[i]
		buf.put_u8(int(t["kind"]) & 0xFF)
		buf.put_u8(clampi(int(t["count"]), 0, 255))
	# M5.5-P2: own suppression scalar quantized to 1 byte for the M7 screen FX (blur/shake/muffle).
	# Rides SELF_STATE (the local player's own state) rather than the per-pawn snapshot, whose
	# field-mask is a full u8 — and remote suppression need not be replicated (spec §2).
	buf.put_u8(int(round(clampf(suppression, 0.0, 1.0) * 255.0)))
	# M5.5-P3: remaining flashbang-blind ticks (1 byte) for the M7 white-out — owner-only, like
	# suppression. Capped at 255 (well above FLASH_BLIND_TICKS).
	buf.put_u8(clampi(blind_ticks, 0, 255))
	# Bandage state for the DBNO self-bandage UI: remaining charges + whether bleed-out is halted.
	# Owner-only (rides SELF_STATE), appended last so older decoders ignore it.
	buf.put_u8(clampi(bandage_count, 0, 255))
	buf.put_u8(1 if bleed_halted else 0)
	return buf.data_array

static func decode_self_state(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var mag := r.get_u8()
	var reloading := r.get_u8() == 1
	var reload_remaining := r.get_u16()
	var weapon := r.get_u8()
	var being_revived := false
	var throwables: Array = []
	var suppression := 0.0
	var blind_ticks := 0
	var bandage_count := 0
	var bleed_halted := false
	if r.get_available_bytes() > 0:
		being_revived = r.get_u8() == 1
	if r.get_available_bytes() > 0:
		var n := r.get_u8()
		for _i in n:
			throwables.append({"kind": r.get_u8(), "count": r.get_u8()})
	if r.get_available_bytes() > 0:
		suppression = float(r.get_u8()) / 255.0
	if r.get_available_bytes() > 0:
		blind_ticks = r.get_u8()
	if r.get_available_bytes() > 0:
		bandage_count = r.get_u8()
	if r.get_available_bytes() > 0:
		bleed_halted = r.get_u8() == 1
	return {"mag": mag, "reloading": reloading, "reload_remaining": reload_remaining, "weapon": weapon, "throwables": throwables, "being_revived": being_revived, "suppression": suppression, "blind_ticks": blind_ticks, "bandage_count": bandage_count, "bleed_halted": bleed_halted}


static func encode_roster(rows: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.ROSTER)
	buf.put_u8(mini(rows.size(), 255))
	for i in mini(rows.size(), 255):
		var rw: Dictionary = rows[i]
		buf.put_u32(int(rw["id"]))
		buf.put_utf8_string(String(rw["name"]))
		buf.put_u8(int(rw["team"]) & 0xFF)
		buf.put_u8(int(rw["squad"]) & 0xFF)
		buf.put_u16(clampi(int(rw["kills"]), 0, 65535))
		buf.put_u16(clampi(int(rw["deaths"]), 0, 65535))
		buf.put_u16(clampi(int(rw["score"]), 0, 65535))
	return buf.data_array

static func decode_roster(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var rows: Array = []
	for _i in n:
		var id := r.get_u32()
		var nm := r.get_utf8_string()
		rows.append({"id": id, "name": nm, "team": r.get_u8(), "squad": r.get_u8(),
			"kills": r.get_u16(), "deaths": r.get_u16(), "score": r.get_u16()})
	return {"rows": rows}


static func encode_set_squad(squad_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SET_SQUAD)
	buf.put_u8(squad_id & 0xFF)
	return buf.data_array

static func decode_set_squad(bytes: PackedByteArray) -> Dictionary:
	return {"squad": body_reader(bytes).get_u8()}


static func encode_death_info(killer_id: int, weapon: int, distance: float, killer_hp: int, attackers: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DEATH_INFO)
	buf.put_u32(killer_id)
	buf.put_u8(weapon & 0xFF)
	buf.put_u16(clampi(roundi(distance * 10.0), 0, 65535))
	buf.put_u8(clampi(killer_hp, 0, 255))
	buf.put_u8(mini(attackers.size(), 255))
	for i in mini(attackers.size(), 255):
		var a: Dictionary = attackers[i]
		buf.put_u32(int(a["id"]))
		buf.put_u16(clampi(int(a["dmg"]), 0, 65535))
	return buf.data_array

static func decode_death_info(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var killer := r.get_u32()
	var weapon := r.get_u8()
	var distance := float(r.get_u16()) / 10.0
	var killer_hp := r.get_u8()
	var n := r.get_u8()
	var attackers: Array = []
	for _i in n:
		attackers.append({"id": r.get_u32(), "dmg": r.get_u16()})
	return {"killer": killer, "weapon": weapon, "distance": distance, "killer_hp": killer_hp, "attackers": attackers}


static func encode_set_fire_mode(mode: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SET_FIRE_MODE)
	buf.put_u8(mode & 0xFF)
	return buf.data_array

static func decode_set_fire_mode(bytes: PackedByteArray) -> int:
	return body_reader(bytes).get_u8()

static func encode_swap_weapon(slot: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SWAP_WEAPON)
	buf.put_u8(slot & 0xFF)
	return buf.data_array

static func decode_swap_weapon(bytes: PackedByteArray) -> int:
	return body_reader(bytes).get_u8()

static func encode_melee() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.MELEE)
	return buf.data_array


static func encode_place_fob(cell: Vector3i, yaw: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.PLACE_FOB)
	buf.put_16(cell.x); buf.put_16(cell.y); buf.put_16(cell.z)
	buf.put_u8(yaw & 0xFF)
	return buf.data_array

static func decode_place_fob(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var cell := Vector3i(r.get_16(), r.get_16(), r.get_16())
	return {"cell": cell, "yaw": r.get_u8()}

static func encode_remove_fob() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REMOVE_FOB)
	return buf.data_array

## Server -> human clients (own team): the team's FOBs. squad u8, structure_id u16,
## flags u8 (bit0 under_construction, bit1 enabled). Rebuilt + sent on change like GADGET_LIST.
static func encode_fob_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.FOB_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var f: Dictionary = list[i]
		buf.put_u8(int(f["squad"]) & 0xFF)
		buf.put_u16(int(f["structure_id"]) & 0xFFFF)
		var flags := (int(f["under_construction"]) & 1) | ((int(f["enabled"]) & 1) << 1)
		buf.put_u8(flags)
	return buf.data_array

static func decode_fob_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var squad := r.get_u8()
		var sid := r.get_u16()
		var flags := r.get_u8()
		out.append({"squad": squad, "structure_id": sid,
			"under_construction": flags & 1, "enabled": (flags >> 1) & 1})
	return out
