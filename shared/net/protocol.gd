class_name Protocol
extends Object
## Wire protocol message (de)serialization. The single source of truth for the
## byte layout used by client, server, and bot driver. This file is the reason
## the three roles can never disagree about the protocol — they all encode/decode
## through here. See docs/AGENTS.md §7.
##
## M0 covers only the connection handshake. M1 extends this with input command
## frames and delta-compressed snapshots (see docs/specs/wire-protocol.md).
##
## VERSION policy: bump on ANY wire change — format (bytes moved/added/removed) OR meaning
## (same bytes, different interpretation, e.g. the 2026-07-02 deploy-ref re-base). The HELLO
## handshake rejects mismatches; this is the ONLY cross-build compat mechanism. Do NOT add
## `get_available_bytes()` trailing-field guards inside repeated records — a guard mid-record
## sees the NEXT record's bytes and misaligns the whole packet (it is only sound at message
## tail). History: VERSION sat at 1 through M1–M12 while the wire changed dozens of times,
## so the check protected nothing; real from 2 onward.

const VERSION := 12   # 12: M19 grapple — DEPLOYED_LADDER_LIST/CUT_LADDER msgs + GA_GRAPPLE_FIRE + SELF_STATE trailing grapple_charges u8 (2026-07-13)
                     # 11: M19 P5 riot shield — BTN_SHIELD bit + SELF_STATE trailing shield_hp_frac u8 (2026-07-12)
                     # 10: M19 P4 LMG Nest — EMPLACEMENT_ACTION/EMPLACEMENT_LIST + GA_LMG_DEPLOY + SELF_STATE mount tail (2026-07-12)
                     # 9: M19 P2b-medic — STIM charges/ticks in SELF_STATE + GA_STIM_USE/GA_SMOKE_WALL_PLACE (2026-07-11)
                     # 7: reliable BULK channel (3) for structure traffic — transport-topology change,
                     # old clients must be rejected (channel-count mismatch); no message format change (2026-07-10)
                     # 6: M17 reserve-ammo economy — SELF_STATE gains a trailing reserve u16 (2026-07-10)
                     # 5: M16 standing-bleed — BANDAGE_ACTION/BLEEDING_LIST msgs + SELF_STATE gains
                     # trailing bleeding-bit + bandage-progress bytes (2026-07-09)

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
	GRENADE_FX = 35,        ## server -> ALL clients (M7.5-P3): a remote pawn threw a grenade (cosmetic arc / bot avoidance)
	GADGET_LIST = 36,       ## server -> ALL clients (M7.5-P3): authoritative deployed gadgets (C4/mine/bag) — render / bot awareness
	SUPPORT_LIST = 37,      ## server -> human clients: active support links (heal/ammo/repair/revive) -> beam + aura
	PLACE_FOB = 38,         ## client -> server: squad leader requests a FOB build site at a cell
	REMOVE_FOB = 39,        ## client -> server: squad leader removes their squad's FOB (site or built)
	FOB_LIST = 40,          ## server -> human clients: their team's FOBs {squad, structure_id, uc, enabled}
	RELOAD_FX = 41,         ## server -> human clients: a remote pawn started reloading (id + duration) -> reload pose
	MELEE_FX = 42,          ## server -> human clients: a remote pawn swung melee (id) -> brief swing/lunge pose
	VAULT_FX = 43,          ## server -> human clients: a remote pawn vaulted (id) -> brief mantle/clamber pose
	DOWNED_LIST = 44,       ## server -> human clients: downed pawns {id, bleed_frac, halted} -> revive-marker urgency
	COLLAPSE_WARNING = 45,  ## server -> clients: a building is about to collapse (id + centre) -> rumble + shake, then COLLAPSE fires ~3 s later
	BANDAGE_ACTION = 46,    ## client -> server (M16): hold-to-bandage a standing-bleeding self/teammate (active-bit + target id)
	BLEEDING_LIST = 47,     ## server -> human clients (M16): standing-bleeding teammate ids -> bleed marker + "hold to bandage" prompt
	SET_LOADOUT = 48,       ## client -> server (M19): player-picked loadout (class/primary/secondary/gadget/armor/grenade + attachment ids); stored, applied at next spawn
	EMPLACEMENT_ACTION = 49,  ## client -> server (M19 P4): mount/dismount a deployed LMG nest (action + nest id)
	EMPLACEMENT_LIST = 50,    ## server -> clients (M19 P4): deployed LMG nests {id,pos,facing,turret,hp_frac,occupant,team}
	DEPLOYED_LADDER_LIST = 51,  ## server -> clients: deployed grapple ladders {id,x,z,bottom_y,top_y,cuttable} -> climb-inject + rope render + cut prompt
	CUT_LADDER = 52,            ## client -> server: request to cut deployed grapple ladder <id> (server-validated: cuttable + in radius + alive)
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
const GA_BREACH_PLACE := 9   # M19: place an Assault breaching charge (pos + facing dir)
const GA_STIM_USE := 10   # M19 P2b: Medic self/team stim injection (pos + facing dir)
const GA_SMOKE_WALL_PLACE := 11   # M19 P2b: Medic smoke-wall gadget placement (pos + facing dir)
const GA_LMG_DEPLOY := 12   # M19 P4: place an LMG nest (pos + facing dir)
const GA_GRAPPLE_FIRE := 13   # M19: fire the grappling hook to deploy a climbable rope-ladder (pos + facing dir)

# VEHICLE_ACTION sub-actions.
const VA_ENTER := 0
const VA_EXIT := 1

# EMPLACEMENT_ACTION sub-actions.
const EA_MOUNT := 0
const EA_DISMOUNT := 1


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
	# Map name is a trailing field — get_string_bounded returns "" when absent OR truncated,
	# so a legacy welcome without it still decodes.
	var map_name := get_string_bounded(r)
	return {"id": id, "tick_rate": tick_rate, "class": cls, "map": map_name}


static func encode_reject(reason: String) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REJECT)
	buf.put_utf8_string(reason)
	return buf.data_array


## Type byte of a message (0 if empty).
static func msg_type(bytes: PackedByteArray) -> int:
	return bytes[0] if not bytes.is_empty() else 0


const MAX_NAME_LEN := 24
# Plus A-Z/a-z/0-9 — see _sanitize_name. Space/dot/apostrophe cover normal names ("O'Brien",
# "Sgt. Ryan"); the rest are common harmless clan-tag/handle decorations. Deliberately excludes
# anything that reads as markup (<>) or has special meaning elsewhere (% \ ` " ; in format
# strings/paths) even though names aren't currently rendered through any markup-parsing UI.
const _ALLOWED_NAME_SYMBOLS := " .-_'()[]{}#@~^!?"

## Bounded replacement for StreamPeerBuffer.get_utf8_string(): the wire format is a u32 length
## prefix + bytes, and get_utf8_string() trusts that attacker-controlled length blindly (a truncated
## HELLO claiming a ~2 GB name reaches the read before _sanitize_name's cap applies). Validates the
## claimed length against the bytes actually present; returns "" on a lying prefix.
static func get_string_bounded(r: StreamPeerBuffer) -> String:
	if r.get_available_bytes() < 4:
		return ""
	var n := r.get_u32()
	if n == 0 or n > r.get_available_bytes():
		return ""
	var res: Array = r.get_data(n)
	if int(res[0]) != OK:
		return ""
	return (res[1] as PackedByteArray).get_string_from_utf8()


## HELLO body: protocol version + player name + auto_deploy (trailing byte, legacy default true).
static func decode_hello(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var ver := r.get_u16()
	var pname := _sanitize_name(get_string_bounded(r))
	var auto_deploy: bool = (r.get_u8() == 1) if r.get_available_bytes() > 0 else true
	return {"ver": ver, "name": pname, "auto_deploy": auto_deploy}


## The HELLO name is attacker-controlled and gets re-broadcast to every peer via ROSTER, so this
## is the trust boundary: cap length (bounds the loop below regardless of how large the client
## sent) and whitelist to [A-Za-z0-9-_()[]{}] — no whitespace/control/punctuation/emoji — before
## it ever reaches other clients' UI.
static func _sanitize_name(raw: String) -> String:
	var capped := raw.substr(0, MAX_NAME_LEN)
	var out := ""
	for c in capped:
		var code := c.unicode_at(0)
		var is_alnum := (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		if is_alnum or _ALLOWED_NAME_SYMBOLS.contains(c):
			out += c
	out = out.strip_edges()   # a name that's all/leading/trailing filler space reads as blank
	return out if not out.is_empty() else "Player"


static func decode_reject(bytes: PackedByteArray) -> String:
	return get_string_bounded(body_reader(bytes))


# ---- shared field codecs ----------------------------------------------------
# World position at 0.1 m in i16 (±3276.7 m — covers the ±1000 m world_half) and unit
# direction at 1e-4 in i16. One implementation for the 9 messages that carry pos/dir;
# clamped (the old per-message copies wrapped in one variant). Callers that want the dir
# normalized do it before put_dir10k — some messages ship the raw aim vector on purpose.

static func put_pos10(buf: StreamPeerBuffer, v: Vector3) -> void:
	buf.put_16(clampi(roundi(v.x * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(v.y * 10.0), -32768, 32767))
	buf.put_16(clampi(roundi(v.z * 10.0), -32768, 32767))


static func get_pos10(r: StreamPeerBuffer) -> Vector3:
	return Vector3(float(r.get_16()) / 10.0, float(r.get_16()) / 10.0, float(r.get_16()) / 10.0)


static func put_dir10k(buf: StreamPeerBuffer, v: Vector3) -> void:
	buf.put_16(clampi(roundi(v.x * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(v.y * 10000.0), -32768, 32767))
	buf.put_16(clampi(roundi(v.z * 10000.0), -32768, 32767))


static func get_dir10k(r: StreamPeerBuffer) -> Vector3:
	return Vector3(float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0, float(r.get_16()) / 10000.0)


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
	# Unconditional: _put_record always writes these. The old trailing guards were unsafe
	# here — this record repeats inside baselines, so a guard would peek the NEXT record's
	# bytes and misalign the packet. Record layout changes require a VERSION bump instead.
	var uc := r.get_u8()
	var prog := r.get_u16()
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

static func encode_collapse_warning(building_id: int, center: Vector3) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.COLLAPSE_WARNING)
	buf.put_u16(building_id)
	put_pos10(buf, center)
	return buf.data_array

static func decode_collapse_warning(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var bid := r.get_u16()
	return {"building_id": bid, "center": get_pos10(r)}


static func encode_grenade_throw(dir: Vector3, type: int, charge: float = 1.0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GRENADE_THROW)
	put_dir10k(buf, dir.normalized())
	buf.put_u8(type)
	buf.put_u8(int(round(clampf(charge, 0.0, 1.0) * 255.0)))   # hold-charge 0..1 -> throw strength
	return buf.data_array


static func decode_grenade_throw(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var dir := get_dir10k(r)
	var type := r.get_u8()
	var charge := 1.0   # old clients (no charge byte) -> full-strength throw
	if r.get_available_bytes() > 0:
		charge = float(r.get_u8()) / 255.0
	return {"dir": dir, "type": type, "charge": charge}


static func encode_smoke_deployed(pos: Vector3, radius: float, expire_tick: int, vel: Vector3 = Vector3.ZERO) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SMOKE_DEPLOYED)
	buf.put_16(clampi(roundi(pos.x), -32768, 32767)); buf.put_16(clampi(roundi(pos.y), -32768, 32767)); buf.put_16(clampi(roundi(pos.z), -32768, 32767))   # clamp like put_pos10 (no i16 wrap)
	buf.put_u8(clampi(roundi(radius), 0, 255))
	buf.put_u16(clampi(expire_tick, 0, 65535))   # absolute tick (u16); fine for gate-length matches
	# Canister velocity AT POP (m/s) so the client can integrate the same fall and the cloud follows the
	# grenade wherever it flies/tumbles to, instead of hanging where the fuse popped. Trailing-optional.
	buf.put_float(vel.x); buf.put_float(vel.y); buf.put_float(vel.z)
	return buf.data_array


static func decode_smoke_deployed(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var pos := Vector3(r.get_16(), r.get_16(), r.get_16())
	var radius := r.get_u8()
	var expire_tick := r.get_u16()
	var vel := Vector3.ZERO   # old senders / short packets: a stationary cloud where it popped
	if r.get_available_bytes() >= 12:
		vel = Vector3(r.get_float(), r.get_float(), r.get_float())
	return {"pos": pos, "radius": radius, "expire_tick": expire_tick, "vel": vel}


static func encode_revive_action(target_id: int, active: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.REVIVE_ACTION)
	buf.put_u32(target_id)
	buf.put_u8(1 if active else 0)
	return buf.data_array


static func decode_revive_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"target": r.get_u32(), "active": r.get_u8() == 1}


## M16 hold-to-bandage: active-bit + target id. target == self ⇒ self-bandage; else a bleeding mate.
static func encode_bandage_action(target_id: int, active: bool) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BANDAGE_ACTION)
	buf.put_u32(target_id)
	buf.put_u8(1 if active else 0)
	return buf.data_array


static func decode_bandage_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"target": r.get_u32(), "active": r.get_u8() == 1}


## M19 loadout select: six small ints (u8) + three attachment ids (u32-length-prefixed strings).
## `primary` is a weapon-variant id (≤ 32 today; u8 has headroom). Stored server-side and applied
## at the next spawn; attachment-id VALIDITY is enforced downstream by Loadout.sanitize (unknown ids
## dropped) — the wire only encodes/decodes them safely.
static func encode_set_loadout(cfg: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SET_LOADOUT)
	buf.put_u8(int(cfg.get("class", 0)))
	buf.put_u8(int(cfg.get("primary", 0)))
	buf.put_u8(int(cfg.get("secondary", 0)))
	buf.put_u8(int(cfg.get("gadget", 0)))
	buf.put_u8(int(cfg.get("armor", 0)))
	buf.put_u8(int(cfg.get("grenade", 0)))
	var att: Dictionary = cfg.get("attachments", {})
	for slot in ["optic", "barrel", "underbarrel"]:
		buf.put_utf8_string(String(att.get(slot, "")))
	return buf.data_array


static func decode_set_loadout(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	# Guard the six fixed bytes: a truncated packet must decode to safe defaults, never error-spam
	# or crash (Loadout.sanitize normalizes the result downstream).
	if r.get_available_bytes() < 6:
		return {"class": 0, "primary": 0, "secondary": 0, "gadget": 0, "armor": 0, "grenade": 0,
			"attachments": {"optic": "", "barrel": "", "underbarrel": ""}}
	var cfg := {
		"class": r.get_u8(), "primary": r.get_u8(), "secondary": r.get_u8(),
		"gadget": r.get_u8(), "armor": r.get_u8(), "grenade": r.get_u8(),
	}
	var att := {}
	for slot in ["optic", "barrel", "underbarrel"]:
		att[slot] = get_string_bounded(r)   # "" if absent/truncated
	cfg["attachments"] = att
	return cfg


static func encode_self_bandage() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SELF_BANDAGE)
	return buf.data_array


static func encode_gadget_action(action: int, pos: Vector3, dir: Vector3, target_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GADGET_ACTION)
	buf.put_u8(action)
	# pos quantized at 0.1 m (i16 ×10 → ±3276 m, covers the ±1000 m world_half; spec sketch)
	put_pos10(buf, pos)   # was the one unclamped copy — clamped now like every sibling
	put_dir10k(buf, dir.normalized() if dir.length() > 0.0001 else Vector3.ZERO)
	buf.put_u32(target_id)
	return buf.data_array


static func decode_gadget_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var action := r.get_u8()
	var pos := get_pos10(r)
	var dir := get_dir10k(r)
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
	put_pos10(buf, pos)
	buf.put_u8(kind & 0xFF)
	return buf.data_array


static func decode_detonation(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"pos": get_pos10(r), "kind": r.get_u8()}


static func encode_shot_fx(origin: Vector3, dir: Vector3, shooter_id: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.SHOT_FX)
	put_pos10(buf, origin)
	put_dir10k(buf, dir)
	buf.put_u32(shooter_id)   # bind the FX to the firing pawn (remote fire-recoil pose)
	return buf.data_array


static func decode_shot_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var origin := get_pos10(r)
	var dir := get_dir10k(r)
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

## Remote melee cue — a remote pawn swung (knife / sledgehammer). Just the swinger id; the client
## plays a brief swing/lunge pose. View-only; sent only to human clients.
static func encode_melee_fx(melee_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.MELEE_FX)
	buf.put_u32(melee_id)
	return buf.data_array

static func decode_melee_fx(bytes: PackedByteArray) -> Dictionary:
	return {"melee_id": body_reader(bytes).get_u32()}

## Remote vault cue — a remote pawn auto-vaulted an obstacle. Just the vaulter id; the client plays
## a brief mantle/clamber pose. View-only; sent only to human clients.
static func encode_vault_fx(vault_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.VAULT_FX)
	buf.put_u32(vault_id)
	return buf.data_array

static func decode_vault_fx(bytes: PackedByteArray) -> Dictionary:
	return {"vault_id": body_reader(bytes).get_u32()}

## RPG rocket launch — same wire shape as SHOT_FX (origin ×10, unit dir ×10000); the client rebuilds
## the velocity from the known rocket speed and flies a cosmetic projectile along the ballistic arc.
static func encode_rocket_fx(origin: Vector3, dir: Vector3) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.ROCKET_FX)
	put_pos10(buf, origin)
	put_dir10k(buf, dir)
	return buf.data_array

static func decode_rocket_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"origin": get_pos10(r), "dir": get_dir10k(r)}

## Remote thrown grenade — same wire shape as ROCKET_FX (origin ×10, look dir ×10000) plus a kind
## byte (Grenade.FRAG/SMOKE); the client rebuilds the launch velocity and arcs a cosmetic grenade.
static func encode_grenade_fx(origin: Vector3, dir: Vector3, kind: int, team: int = 0, charge: float = 1.0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GRENADE_FX)
	put_pos10(buf, origin)
	put_dir10k(buf, dir)
	buf.put_u8(clampi(kind, 0, 255))
	buf.put_u8(clampi(team, 0, 255))                          # thrower team: client warns only for enemy nades
	buf.put_u8(int(round(clampf(charge, 0.0, 1.0) * 255.0)))  # so the remote arc matches the charged throw
	return buf.data_array

static func decode_grenade_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var origin := get_pos10(r)
	var dir := get_dir10k(r)
	var kind := r.get_u8()
	var team := 0
	var charge := 1.0
	if r.get_available_bytes() > 0:
		team = r.get_u8()
	if r.get_available_bytes() > 0:
		charge = float(r.get_u8()) / 255.0
	return {"origin": origin, "dir": dir, "kind": kind, "team": team, "charge": charge}

## Authoritative deployed-gadget list — each entry: kind byte (GadgetList.C4/MINE/BAG), pos ×10, then
## two int16 slots. For C4/MINE those slots are facing x/z ×10000 (zero for C4). For BAG (which never
## has a facing) the same two slots instead carry view-only `subtype` (Gadget.KIND_HEAL/KIND_AMMO) and
## owner `team` — presentation metadata only (right glyph + friendly-only ring), no size change, no
## gameplay authority. The client replaces its rendered gadget set on each receipt.
static func encode_gadget_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.GADGET_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var g: Dictionary = list[i]
		var pos: Vector3 = g["pos"]
		var kind: int = clampi(int(g["kind"]), 0, 255)
		buf.put_u8(kind)
		put_pos10(buf, pos)
		if kind == GadgetList.BAG:
			# Bags carry no facing — reuse the two slots for view-only subtype + team (small ints).
			buf.put_16(clampi(int(g.get("subtype", 0)), -32768, 32767))
			buf.put_16(clampi(int(g.get("team", 0)), -32768, 32767))
		else:
			# face is x/z only (2 components, yaw plane) — not the shared 3-component dir codec.
			var face: Vector3 = g.get("face", Vector3.ZERO)
			buf.put_16(clampi(roundi(face.x * 10000.0), -32768, 32767))
			buf.put_16(clampi(roundi(face.z * 10000.0), -32768, 32767))
	return buf.data_array

static func decode_gadget_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var kind := r.get_u8()
		var pos := get_pos10(r)
		var s0 := r.get_16()
		var s1 := r.get_16()
		if kind == GadgetList.BAG:
			out.append({"kind": kind, "pos": pos, "face": Vector3.ZERO, "subtype": s0, "team": s1})
		else:
			out.append({"kind": kind, "pos": pos, "face": Vector3(float(s0) / 10000.0, 0.0, float(s1) / 10000.0)})
	return out

static func encode_emplacement_action(action: int, nest_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.EMPLACEMENT_ACTION)
	buf.put_u8(action)
	buf.put_u32(nest_id)
	return buf.data_array

static func decode_emplacement_action(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"action": r.get_u8(), "nest_id": r.get_u32()}

## Deployed LMG nests, rebuilt + sent each tick like GADGET_LIST (self-healing render list).
## Per nest: id u32, pos ×10, facing_yaw ×10000 i16, turret_yaw ×10000 i16, hp_frac u8 (×255),
## occupant u32, team u8.
static func encode_emplacement_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.EMPLACEMENT_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var e: Dictionary = list[i]
		buf.put_u32(int(e["id"]))
		put_pos10(buf, e["pos"])
		buf.put_16(clampi(roundi(float(e["facing_yaw"]) * 10000.0), -32768, 32767))
		buf.put_16(clampi(roundi(float(e["turret_yaw"]) * 10000.0), -32768, 32767))
		buf.put_u8(clampi(roundi(float(e["hp_frac"]) * 255.0), 0, 255))
		buf.put_u32(int(e.get("occupant", 0)))
		buf.put_u8(clampi(int(e.get("team", 0)), 0, 255))
	return buf.data_array

static func decode_emplacement_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var id := r.get_u32()
		var pos := get_pos10(r)
		var facing := float(r.get_16()) / 10000.0
		var turret := float(r.get_16()) / 10000.0
		var hp_frac := float(r.get_u8()) / 255.0
		var occ := r.get_u32()
		var team := r.get_u8()
		out.append({"id": id, "pos": pos, "facing_yaw": facing, "turret_yaw": turret,
			"hp_frac": hp_frac, "occupant": occ, "team": team})
	return out

## Deployed grapple ladders, rebuilt + sent each tick like EMPLACEMENT_LIST (self-healing render
## list). Per ladder: id u32, x/z/bottom_y/top_y ×10 i16 (0.1 m), cuttable u8 bool.
static func encode_deployed_ladder_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DEPLOYED_LADDER_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var l: Dictionary = list[i]
		buf.put_u32(int(l["id"]))
		buf.put_16(clampi(roundi(float(l["x"]) * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(float(l["z"]) * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(float(l["bottom_y"]) * 10.0), -32768, 32767))
		buf.put_16(clampi(roundi(float(l["top_y"]) * 10.0), -32768, 32767))
		buf.put_u8(1 if bool(l.get("cuttable", false)) else 0)
	return buf.data_array

static func decode_deployed_ladder_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var id := r.get_u32()
		var x := float(r.get_16()) / 10.0
		var z := float(r.get_16()) / 10.0
		var by := float(r.get_16()) / 10.0
		var ty := float(r.get_16()) / 10.0
		var cut := r.get_u8() == 1
		out.append({"id": id, "x": x, "z": z, "bottom_y": by, "top_y": ty, "cuttable": cut})
	return out

static func encode_cut_ladder(ladder_id: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.CUT_LADDER)
	buf.put_u32(ladder_id)
	return buf.data_array

static func decode_cut_ladder(bytes: PackedByteArray) -> Dictionary:
	return {"ladder_id": body_reader(bytes).get_u32()}

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

## Downed pawns (M7 revive urgency): each entry is id u32 + bleed_frac u8 + flags u8
## (bit0 = bleed halted by self-bandage). bleed_frac is 255 at the moment of going down and drains
## to 0 at the bleed-out floor — it drives the revive marker's colour/pulse so a client can tell how
## close a downed teammate is to dying. No coordinates: the client resolves the id from its own
## snapshot (it already renders the downed marker) and skips ids it can't see. Rebuilt + sent on
## change like GADGET_LIST/SUPPORT_LIST; view-only.
static func encode_downed_list(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.DOWNED_LIST)
	var n: int = mini(list.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		var e: Dictionary = list[i]
		buf.put_u32(int(e["id"]))
		buf.put_u8(clampi(int(e["frac"]), 0, 255))
		buf.put_u8(1 if bool(e.get("halted", false)) else 0)
	return buf.data_array

static func decode_downed_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		var id := r.get_u32()
		var frac := r.get_u8()
		var halted := r.get_u8() != 0
		out.append({"id": id, "frac": frac, "halted": halted})
	return out

## M16: standing-bleeding teammate ids (ally-only, reliable — same pattern as DOWNED_LIST). Drives a
## distinct bleeding marker + "hold interact to bandage" prompt on the client.
static func encode_bleeding_list(ids: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.BLEEDING_LIST)
	var n: int = mini(ids.size(), 255)
	buf.put_u8(n)
	for i in range(n):
		buf.put_u32(int(ids[i]))
	return buf.data_array

static func decode_bleeding_list(bytes: PackedByteArray) -> Array:
	var r := body_reader(bytes)
	var n := r.get_u8()
	var out: Array = []
	for i in range(n):
		out.append(r.get_u32())
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
	put_pos10(buf, pos)
	buf.put_u8(kind)
	return buf.data_array

static func decode_impact_fx(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	return {"pos": get_pos10(r), "kind": r.get_u8()}


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


static func encode_self_state(mag: int, reloading: bool, reload_remaining: int, weapon: int, throwables: Array = [], being_revived: bool = false, suppression: float = 0.0, blind_ticks: int = 0, bandage_count: int = 0, bleed_halted: bool = false, repair_heat: float = 0.0, repair_cooldown: float = 0.0, stamina: float = 100.0, vel_y: float = 0.0, grounded: bool = true, vaulting: bool = false, vault_tick: int = 0, regen_cooldown: float = 0.0, sprint_locked: bool = false, input_buf_depth: int = 0, bleeding: bool = false, bandage_progress: int = 0, reserve: int = 0, stim_charges: int = 0, stim_ticks: int = 0, mounted_nest: int = 0, mg_heat: int = 0, mg_ammo: int = 0, mg_overheated: bool = false, shield_hp_frac: int = 0, grapple_charges: int = 0) -> PackedByteArray:
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
	# Engineer repair-tool heat (M7 HUD gauge): current heat toward overheat and, once overheated,
	# the remaining cooldown-lockout fraction — both 0..1 quantized to a byte. Owner-only (rides
	# SELF_STATE), appended last so older decoders ignore them. Zero for non-engineers / not repairing.
	buf.put_u8(int(round(clampf(repair_heat, 0.0, 1.0) * 255.0)))
	buf.put_u8(int(round(clampf(repair_cooldown, 0.0, 1.0) * 255.0)))
	# Authoritative stamina (0..100 fits a byte) for client sprint-prediction reconcile. Owner-only
	# (rides SELF_STATE), appended last so older decoders ignore it. Without it the client double-drains
	# stamina during replay and rubber-bands while sprinting.
	buf.put_u8(clampi(int(round(stamina)), 0, 255))
	# Authoritative vertical velocity + grounded flag for the client JUMP-prediction reconcile. Owner-only
	# (rides SELF_STATE), appended last so older decoders ignore them. Without them the client keeps a
	# stale velocity.y through reconcile and the jump arc rubber-bands ("pulled back" mid-jump).
	buf.put_float(vel_y)
	buf.put_u8(1 if grounded else 0)
	# Authoritative vault progress for the client VAULT-prediction reconcile. Owner-only, appended
	# last so older decoders ignore it. Without it a reconcile mid-vault kept the stale local arc
	# (which overrides the authoritative position) and every replayed input advanced the 8-tick arc
	# again — the predicted vault finished (1+pending)x too fast and stuttered every auto-vault.
	buf.put_u8(1 if vaulting else 0)
	buf.put_u8(clampi(vault_tick, 0, 255))
	# Authoritative stamina regen-cooldown for the client SPRINT/JUMP-stamina reconcile (fixes the
	# deferred C6). Without it the client's _regen_cooldown drifts from the server's, so predicted
	# stamina diverges exactly at the boundaries that matter — empty-sprint (sprint flickers on/off,
	# ~1 Hz snap) and the JUMP_COST threshold (the jump fires a tick apart -> the arc apex snaps).
	# Owner-only, appended last so older decoders ignore it. Normalized to STAMINA_REGEN_DELAY.
	buf.put_u8(clampi(roundi(regen_cooldown / Pawn.STAMINA_REGEN_DELAY * 255.0), 0, 255))
	# Authoritative sprint-lockout flag for the empty-sprint hysteresis reconcile. Owner-only, appended
	# last so older decoders ignore it. Without it a reconcile mid-recovery keeps the client's stale
	# lock state (neither stamina==0 nor >=SPRINT_RESUME during recovery, so the flag never recomputes)
	# and the client mis-predicts sprint vs walk through the whole recovery window.
	buf.put_u8(1 if sprint_locked else 0)
	# Tick-lead netcode (docs/specs/netcode-tick-lead.md): the per-client InputBuffer depth sampled
	# right after this tick's drain. The owner client nudges its input-production clock to hold this
	# at TickLead.TARGET, so starvation/coalescing (the wandering reconcile-replay length -> the ~1 Hz
	# movement micro-snap) become rare. Owner-only, appended last so older decoders ignore it.
	buf.put_u8(clampi(input_buf_depth, 0, 255))
	# M16 standing bleed (owner-only, appended last so older decoders ignore them): whether the owner
	# is currently standing-bleeding (drives the red bleeding vignette) and, when the owner is the
	# target of an active bandage channel, its 0..255 progress fraction (drives the bandage cast-bar).
	buf.put_u8(1 if bleeding else 0)
	buf.put_u8(clampi(bandage_progress, 0, 255))
	# M17 reserve-ammo economy (owner-only, appended last so older decoders ignore it): the
	# spare-bullet pool separate from the loaded mag. u16 — full reserves (up to ~210) exceed a byte.
	buf.put_u16(clampi(reserve, 0, 65535))
	# M19 P2b-medic (owner-only, appended last so older decoders ignore them): remaining stim
	# charges (Medic's syringe pool) and the ticks left on an active stim buff.
	buf.put_u8(clampi(stim_charges, 0, 255))
	buf.put_u16(clampi(stim_ticks, 0, 65535))
	# M19 P4 LMG Nest (owner-only, appended last so older decoders ignore them): which nest the
	# owner is mounted in (0 = none) and the mounted LMG's overheat gauge/ammo for the HUD.
	buf.put_u32(mounted_nest)
	buf.put_u8(clampi(mg_heat, 0, 255))
	buf.put_u16(clampi(mg_ammo, 0, 65535))
	buf.put_u8(1 if mg_overheated else 0)
	# M19 P5: owner-only shield-HP fraction (0-255), appended last so older decoders ignore it.
	buf.put_u8(shield_hp_frac & 0xFF)
	# M19 grapple: owner-only remaining grapple charges (0/1), appended last so older decoders ignore it.
	buf.put_u8(clampi(grapple_charges, 0, 255))
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
	var repair_heat := 0.0
	var repair_cooldown := 0.0
	var stamina := 100.0   # full by default so a short/old packet never wrongly stalls sprint prediction
	var vel_y := 0.0       # standing still by default
	var grounded := true   # on the ground by default so an old/short packet never mis-predicts a jump
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
	if r.get_available_bytes() > 0:
		repair_heat = float(r.get_u8()) / 255.0
	if r.get_available_bytes() > 0:
		repair_cooldown = float(r.get_u8()) / 255.0
	if r.get_available_bytes() > 0:
		stamina = float(r.get_u8())
	if r.get_available_bytes() >= 4:
		vel_y = r.get_float()
	if r.get_available_bytes() > 0:
		grounded = r.get_u8() == 1
	var vaulting := false   # not vaulting by default so an old/short packet never freezes the pawn mid-arc
	var vault_tick := 0
	if r.get_available_bytes() > 0:
		vaulting = r.get_u8() == 1
	if r.get_available_bytes() > 0:
		vault_tick = r.get_u8()
	var regen_cooldown := 0.0   # 0 by default: an old/short packet lets stamina regen immediately (harmless)
	if r.get_available_bytes() > 0:
		regen_cooldown = float(r.get_u8()) / 255.0 * Pawn.STAMINA_REGEN_DELAY
	var sprint_locked := false   # not locked by default so an old/short packet never wrongly stalls sprint
	if r.get_available_bytes() > 0:
		sprint_locked = r.get_u8() == 1
	var input_buf_depth := -1   # -1 sentinel: absent -> tick-lead loop stays idle (never mis-corrects)
	if r.get_available_bytes() > 0:
		input_buf_depth = r.get_u8()
	var bleeding := false        # M16: not bleeding by default so an old/short packet never wrongly vignettes
	var bandage_progress := 0
	if r.get_available_bytes() > 0:
		bleeding = r.get_u8() == 1
	if r.get_available_bytes() > 0:
		bandage_progress = r.get_u8()
	var reserve := -1   # M17: -1 sentinel when a pre-6 packet omits it → client keeps its predicted reserve
	if r.get_available_bytes() >= 2:
		reserve = r.get_u16()
	var stim_charges := 0   # M19 P2b: 0 by default so an old/short packet never shows phantom stim charges
	var stim_ticks := 0
	if r.get_available_bytes() > 0:
		stim_charges = r.get_u8()
	if r.get_available_bytes() >= 2:
		stim_ticks = r.get_u16()
	# M19 P4 LMG Nest: owner-only mount tail, guarded like the rest of the trailing fields so an
	# older/short packet just leaves the local player unmounted rather than misaligning the read.
	# NOTE: all four fields share ONE >= 8 guard on purpose — they are a single semantic unit
	# (mounted-or-not, always written together). Do NOT split into per-field guards.
	var mounted_nest := 0
	var mg_heat := 0
	var mg_ammo := 0
	var mg_overheated := false
	if r.get_available_bytes() >= 8:
		mounted_nest = r.get_u32()
		mg_heat = r.get_u8()
		mg_ammo = r.get_u16()
		mg_overheated = r.get_u8() == 1
	# M19 P5 riot shield: owner-only shield-HP fraction, appended last so an older/short packet
	# just leaves it at 0 (no shield) rather than misaligning the read.
	var shield_hp_frac := 0
	if r.get_available_bytes() >= 1:
		shield_hp_frac = r.get_u8()
	# M19 grapple: owner-only remaining grapple charges, appended after shield_hp_frac; an
	# older/short packet just leaves it at 0 rather than misaligning the read.
	var grapple_charges := 0
	if r.get_available_bytes() >= 1:
		grapple_charges = r.get_u8()
	return {"mag": mag, "reloading": reloading, "reload_remaining": reload_remaining, "weapon": weapon, "throwables": throwables, "being_revived": being_revived, "suppression": suppression, "blind_ticks": blind_ticks, "bandage_count": bandage_count, "bleed_halted": bleed_halted, "repair_heat": repair_heat, "repair_cooldown": repair_cooldown, "stamina": stamina, "vel_y": vel_y, "grounded": grounded, "vaulting": vaulting, "vault_tick": vault_tick, "regen_cooldown": regen_cooldown, "sprint_locked": sprint_locked, "input_buf_depth": input_buf_depth, "bleeding": bleeding, "bandage_progress": bandage_progress, "reserve": reserve, "stim_charges": stim_charges, "stim_ticks": stim_ticks, "mounted_nest": mounted_nest, "mg_heat": mg_heat, "mg_ammo": mg_ammo, "mg_overheated": mg_overheated, "shield_hp_frac": shield_hp_frac, "grapple_charges": grapple_charges}


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
		var nm := get_string_bounded(r)
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

static func encode_melee(view_server_tick: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Msg.MELEE)
	buf.put_u32(view_server_tick)   # rendered-time tick so the server lag-comp rewinds targets like bullets
	return buf.data_array

static func decode_melee(bytes: PackedByteArray) -> Dictionary:
	var r := body_reader(bytes)
	var vt := 0
	if r.get_available_bytes() >= 4:
		vt = r.get_u32()   # zero (or absent) => present-time, back-compatible with old clients
	return {"view_server_tick": vt}


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
