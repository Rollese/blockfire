class_name VoicePacket
extends RefCounted
## Pure VOICE wire codec. Header = u16 speaker_id | u8 kind | u16 seq | u16 frame_len, then frame.
## Sent on the dedicated voice host (separate UDP port), unreliable. No engine deps.

const KIND_PROXIMITY := 0
const KIND_SQUAD := 1
const HEADER_BYTES := 7
const MAX_OPUS_FRAME_BYTES := 256

static func encode(speaker_id: int, kind: int, seq: int, frame: PackedByteArray) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u16(speaker_id)
	buf.put_u8(kind)
	buf.put_u16(seq)
	buf.put_u16(frame.size())
	buf.put_data(frame)
	return buf.data_array

## Returns {} on any malformed input (never throws); else {speaker_id, kind, seq, frame}.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_BYTES:
		return {}
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	var speaker_id := buf.get_u16()
	var kind := buf.get_u8()
	var seq := buf.get_u16()
	var flen := buf.get_u16()
	if kind != KIND_PROXIMITY and kind != KIND_SQUAD:
		return {}
	if flen > MAX_OPUS_FRAME_BYTES or flen != bytes.size() - HEADER_BYTES:
		return {}
	var res: Array = buf.get_data(flen)
	var frame: PackedByteArray = res[1]
	return {"speaker_id": speaker_id, "kind": kind, "seq": seq, "frame": frame}
