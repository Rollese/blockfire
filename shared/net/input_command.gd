class_name InputCommand
extends Object
## Client -> server input frame(s). Each INPUT packet carries a BUNDLE of the last N input frames
## (redundancy against packet loss): the server applies any frames it has not seen yet, so an
## isolated dropped packet no longer staves the server's view of the player (rubber-band + bots
## losing track). ack_seq is per-packet (latest acked snapshot). Each frame: move_x/move_y are
## world-space intent in [-1,1] (i16); yaw/pitch are angles (u16); buttons is a bitmask;
## view_server_tick is the server tick the client was interpolating at send time (for lag comp).

const MOVE_SCALE := 32767.0

const BTN_JUMP := 1
const BTN_CROUCH := 2
const BTN_PRONE := 4
const BTN_SPRINT := 8
const BTN_LEAN_L := 16
const BTN_LEAN_R := 32
const BTN_FIRE := 64
const BTN_RELOAD := 128
const BTN_AIM := 256   # aim-down-sights (bit 9 -> buttons is a u16 on the wire)
const BTN_SHOVEL := 512    # bit 9: held shovel-use (M12-P2 build/repair/dismantle); server-computed

## Encode a single-frame bundle. Convenience wrapper kept for the bot driver and old call sites;
## the rendered client uses encode_bundle() to send the last N frames for redundancy.
static func encode(client_tick: int, ack_seq: int, move_x: float, move_y: float,
		yaw: float, pitch: float, buttons: int, view_server_tick: int = 0) -> PackedByteArray:
	return encode_bundle(ack_seq, [{
		"client_tick": client_tick, "move_x": move_x, "move_y": move_y,
		"yaw": yaw, "pitch": pitch, "buttons": buttons, "view_server_tick": view_server_tick,
	}])

## Encode a bundle of input frames (ordered oldest -> newest). Frame count is a u8 prefix.
static func encode_bundle(ack_seq: int, frames: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.Msg.INPUT)
	buf.put_u32(ack_seq)
	buf.put_u8(frames.size() & 0xFF)
	for f in frames:
		_put_frame(buf, f)
	return buf.data_array

static func _put_frame(buf: StreamPeerBuffer, f: Dictionary) -> void:
	buf.put_u32(int(f["client_tick"]))
	buf.put_u32(int(f.get("view_server_tick", 0)))
	buf.put_16(clampi(roundi(clampf(float(f["move_x"]), -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_16(clampi(roundi(clampf(float(f["move_y"]), -1.0, 1.0) * MOVE_SCALE), -32767, 32767))
	buf.put_u16(Quantize.enc_angle(float(f["yaw"])))
	buf.put_u16(Quantize.enc_angle(float(f["pitch"])))
	buf.put_u16(int(f["buttons"]) & 0xFFFF)   # u16: room for BTN_AIM (bit 9) beyond the 8 movement/fire bits

## Decode an INPUT packet into {ack_seq, frames:[...]} with frames ordered oldest -> newest.
## Each frame dict has the same shape consumed by the server sim (client_tick, move_x, move_y,
## yaw, pitch, buttons, view_server_tick).
static func decode(bytes: PackedByteArray) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	buf.seek(1)  # skip msg type
	var ack_seq := buf.get_u32()
	var n := buf.get_u8()
	var frames: Array = []
	for _i in n:
		frames.append(_get_frame(buf))
	return {"ack_seq": ack_seq, "frames": frames}

static func _get_frame(buf: StreamPeerBuffer) -> Dictionary:
	return {
		"client_tick": buf.get_u32(),
		"view_server_tick": buf.get_u32(),
		"move_x": float(buf.get_16()) / MOVE_SCALE,
		"move_y": float(buf.get_16()) / MOVE_SCALE,
		"yaw": Quantize.dec_angle(buf.get_u16()),
		"pitch": Quantize.dec_angle(buf.get_u16()),
		"buttons": buf.get_u16(),
	}
