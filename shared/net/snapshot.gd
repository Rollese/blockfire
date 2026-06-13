class_name Snapshot
extends Object
## Baseline + delta snapshot codec. current/baseline are Dictionary[int id -> EntityState].
## A client holding `baseline` and applying the produced bytes arrives exactly at `current`.
## See docs/specs/m1-netcode-core.md.

# field_mask bits
const F_POS_X := 1
const F_POS_Y := 2
const F_POS_Z := 4
const F_YAW := 8
const F_ALL := 15

# per-record flags
const FLAG_ENTER := 1
const FLAG_LEAVE := 2
const FLAG_CHANGED := 4


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
			recs.put_u32(id)
			recs.put_u8(FLAG_CHANGED)
			_put_fields(recs, cur, mask)
		else:
			count += 1
			recs.put_u32(id)
			recs.put_u8(FLAG_ENTER)
			_put_fields(recs, cur, F_ALL)

	for id in baseline:
		if not current.has(id):
			count += 1
			recs.put_u32(id)
			recs.put_u8(FLAG_LEAVE)

	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.SNAPSHOT)
	buf.put_u32(server_tick)
	buf.put_u32(seq)
	buf.put_u32(baseline_seq)
	buf.put_u32(last_input_tick)
	buf.put_u16(count)
	if count > 0:
		buf.put_data(recs.data_array)
	return buf.data_array


## Applies the snapshot to `view` (mutated in place). Returns the header fields.
static func decode_apply(bytes: PackedByteArray, view: Dictionary) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)  # skip msg type
	var server_tick := buf.get_u32()
	var seq := buf.get_u32()
	var baseline_seq := buf.get_u32()
	var last_input_tick := buf.get_u32()
	var count := buf.get_u16()
	for _i in count:
		var id := buf.get_u32()
		var flags := buf.get_u8()
		if flags & FLAG_LEAVE:
			view.erase(id)
			continue
		var mask := buf.get_u8()
		var e: EntityState = view.get(id)
		if e == null:
			e = EntityState.new()
			view[id] = e
		if mask & F_POS_X: e.pos.x = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Y: e.pos.y = Quantize.dec_pos(buf.get_32())
		if mask & F_POS_Z: e.pos.z = Quantize.dec_pos(buf.get_32())
		if mask & F_YAW:   e.yaw = Quantize.dec_angle(buf.get_u16())
	return {
		"server_tick": server_tick, "seq": seq,
		"baseline_seq": baseline_seq, "last_input_tick": last_input_tick,
	}


static func _diff_mask(a: EntityState, b: EntityState) -> int:
	var m := 0
	if Quantize.enc_pos(a.pos.x) != Quantize.enc_pos(b.pos.x): m |= F_POS_X
	if Quantize.enc_pos(a.pos.y) != Quantize.enc_pos(b.pos.y): m |= F_POS_Y
	if Quantize.enc_pos(a.pos.z) != Quantize.enc_pos(b.pos.z): m |= F_POS_Z
	if Quantize.enc_angle(a.yaw) != Quantize.enc_angle(b.yaw): m |= F_YAW
	return m


static func _put_fields(buf: StreamPeerBuffer, e: EntityState, mask: int) -> void:
	buf.put_u8(mask)
	if mask & F_POS_X: buf.put_32(Quantize.enc_pos(e.pos.x))
	if mask & F_POS_Y: buf.put_32(Quantize.enc_pos(e.pos.y))
	if mask & F_POS_Z: buf.put_32(Quantize.enc_pos(e.pos.z))
	if mask & F_YAW:   buf.put_u16(Quantize.enc_angle(e.yaw))
