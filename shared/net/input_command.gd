class_name InputCommand
extends Object
## Client -> server input frame. move_x/move_y are intent in [-1,1] (i16); yaw/pitch
## are angles (u16); buttons is a bitmask; view_server_tick is the server tick the
## client was interpolating at send time (for lag compensation). See M2 spec.

const MOVE_SCALE := 32767.0

const BTN_JUMP := 1
const BTN_CROUCH := 2
const BTN_PRONE := 4
const BTN_SPRINT := 8
const BTN_LEAN_L := 16
const BTN_LEAN_R := 32
const BTN_FIRE := 64
const BTN_RELOAD := 128

static func encode(client_tick: int, ack_seq: int, move_x: float, move_y: float,
		yaw: float, pitch: float, buttons: int, view_server_tick: int = 0) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.INPUT)
	buf.put_u32(client_tick)
	buf.put_u32(ack_seq)
	buf.put_u32(view_server_tick)
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
		"view_server_tick": buf.get_u32(),
		"move_x": float(buf.get_16()) / MOVE_SCALE,
		"move_y": float(buf.get_16()) / MOVE_SCALE,
		"yaw": Quantize.dec_angle(buf.get_u16()),
		"pitch": Quantize.dec_angle(buf.get_u16()),
		"buttons": buf.get_u8(),
	}
