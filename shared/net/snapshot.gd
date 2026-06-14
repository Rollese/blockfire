class_name Snapshot
extends Object
## Baseline + delta snapshot codec. current/baseline are Dictionary[int id -> EntityState].
## A client holding `baseline` and applying the bytes arrives exactly at `current`.
## baseline_seq == 0 is a keyframe: the receiver resets its view to this snapshot. See M2 spec.

# field_mask bits
const F_POS_X := 1
const F_POS_Y := 2
const F_POS_Z := 4
const F_YAW := 8
const F_PITCH := 16
const F_STATE := 32   # packed: stance(0-1) | lean(2-3) | team(4) | alive(5)
const F_HEALTH := 64
const F_SQUAD := 128
const F_ALL := 255

# per-record flags
const FLAG_ENTER := 1
const FLAG_LEAVE := 2
const FLAG_CHANGED := 4

static func _state_byte(e: EntityState) -> int:
	return (e.stance & 3) | ((e.lean & 3) << 2) | ((1 if e.team != 0 else 0) << 4) | ((1 if e.alive else 0) << 5)

static func encode(server_tick: int, seq: int, baseline_seq: int, last_input_tick: int,
		current: Dictionary, baseline: Dictionary) -> PackedByteArray:
	var recs := StreamPeerBuffer.new()
	var count := 0
	for id in current:
		var cur: EntityState = current[id]
		if baseline.has(id):
			var mask := _diff_mask(baseline[id], cur)
			if mask == 0:
				continue
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_CHANGED); _put_fields(recs, cur, mask)
		else:
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_ENTER); _put_fields(recs, cur, F_ALL)
	for id in baseline:
		if not current.has(id):
			count += 1
			recs.put_u32(id); recs.put_u8(FLAG_LEAVE)

	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.SNAPSHOT)
	buf.put_u32(server_tick); buf.put_u32(seq); buf.put_u32(baseline_seq); buf.put_u32(last_input_tick)
	buf.put_u16(count)
	if count > 0:
		buf.put_data(recs.data_array)
	return buf.data_array

static func decode_apply(bytes: PackedByteArray, view: Dictionary) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)
	var server_tick := buf.get_u32()
	var seq := buf.get_u32()
	var baseline_seq := buf.get_u32()
	var last_input_tick := buf.get_u32()
	var count := buf.get_u16()
	if baseline_seq == 0:
		view.clear()
	for _i in count:
		var id := buf.get_u32()
		var flags := buf.get_u8()
		if flags & FLAG_LEAVE:
			view.erase(id); continue
		var mask := buf.get_u8()
		var e: EntityState = view.get(id)
		if e == null:
			e = EntityState.new(); view[id] = e
		if mask & F_POS_X: e.pos.x = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Y: e.pos.y = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Z: e.pos.z = Quantize.dec_pos(buf.get_32())
		if mask & F_YAW:   e.yaw = Quantize.dec_angle(buf.get_u16())
		if mask & F_PITCH:
			var p := Quantize.dec_angle(buf.get_u16())
			e.pitch = p - TAU if p > PI else p   # recover signed pitch
		if mask & F_STATE:
			var sb := buf.get_u8()
			e.stance = sb & 3
			e.lean = (sb >> 2) & 3
			e.team = (sb >> 4) & 1
			e.alive = ((sb >> 5) & 1) == 1
		if mask & F_HEALTH: e.health = buf.get_u8()
		if mask & F_SQUAD: e.squad = buf.get_u8()
	return {"server_tick": server_tick, "seq": seq, "baseline_seq": baseline_seq, "last_input_tick": last_input_tick}

static func _diff_mask(a: EntityState, b: EntityState) -> int:
	var m := 0
	if Quantize.enc_pos(a.pos.x) != Quantize.enc_pos(b.pos.x): m |= F_POS_X
	if Quantize.enc_pos(a.pos.y) != Quantize.enc_pos(b.pos.y): m |= F_POS_Y
	if Quantize.enc_pos(a.pos.z) != Quantize.enc_pos(b.pos.z): m |= F_POS_Z
	if Quantize.enc_angle(a.yaw) != Quantize.enc_angle(b.yaw): m |= F_YAW
	if Quantize.enc_angle(a.pitch) != Quantize.enc_angle(b.pitch): m |= F_PITCH
	if _state_byte(a) != _state_byte(b): m |= F_STATE
	if a.health != b.health: m |= F_HEALTH
	if a.squad != b.squad: m |= F_SQUAD
	return m

static func _put_fields(buf: StreamPeerBuffer, e: EntityState, mask: int) -> void:
	buf.put_u8(mask)
	if mask & F_POS_X: buf.put_32(Quantize.enc_pos(e.pos.x))
	if mask & F_POS_Y: buf.put_32(Quantize.enc_pos(e.pos.y))
	if mask & F_POS_Z: buf.put_32(Quantize.enc_pos(e.pos.z))
	if mask & F_YAW:   buf.put_u16(Quantize.enc_angle(e.yaw))
	if mask & F_PITCH: buf.put_u16(Quantize.enc_angle(e.pitch))
	if mask & F_STATE: buf.put_u8(_state_byte(e))
	if mask & F_HEALTH: buf.put_u8(clampi(e.health, 0, 255))
	if mask & F_SQUAD: buf.put_u8(e.squad & 0xFF)
