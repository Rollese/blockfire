class_name InputCommand
extends Object
## Client -> server input frame. move_x/move_y are intent in [-1,1] (i16-quantized);
## yaw/pitch are angles (u16). See docs/specs/m1-netcode-core.md.

const MOVE_SCALE := 32767.0

static func encode(client_tick: int, ack_seq: int, move_x: float, move_y: float,
		yaw: float, pitch: float, buttons: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.INPUT)
	buf.put_u32(client_tick)
	buf.put_u32(ack_seq)
	buf.put_16(clampi(roundi(clampf(move_x, -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_16(clampi(roundi(clampf(move_y, -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_u16(Quantize.enc_angle(yaw))
	buf.put_u16(Quantize.enc_angle(pitch))
	buf.put_u8(buttons & 0xFF)
	return buf.data_array

static func decode(bytes: PackedByteArray) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)  # skip msg type
	return {
		"client_tick": buf.get_u32(),
		"ack_seq": buf.get_u32(),
		"move_x": float(buf.get_16()) / MOVE_SCALE,
		"move_y": float(buf.get_16()) / MOVE_SCALE,
		"yaw": Quantize.dec_angle(buf.get_u16()),
		"pitch": Quantize.dec_angle(buf.get_u16()),
		"buttons": buf.get_u8(),
	}
