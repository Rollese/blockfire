class_name VoiceRelay
extends RefCounted
## NOTE: the ENet thread/socket relay shell (start/run/_handle/stop) is DEFERRED to Phase 2 integration; this file currently holds only the pure, tested process_frame decision.
## Voice relay decision core. process_frame() is the pure, tested decision;
## the thread/socket shell is deferred to Phase 2 integration.

const VOICE_PORT := 7778

## PURE decision: returns {recipients: Array[int peer], frame: PackedByteArray}.
## Decodes the inbound frame, computes recipients via VoiceRouting,
## maps player ids to voice_peer ints, and re-encodes with the trusted speaker id.
## Malformed inbound → {"recipients": [], "frame": PackedByteArray()}.
static func process_frame(trusted_speaker: int, inbound: PackedByteArray,
		table: Dictionary, prox_range: float, max_fanout: int) -> Dictionary:
	var d := VoicePacket.decode(inbound)
	if d.is_empty():
		return {"recipients": [], "frame": PackedByteArray()}
	var ids := VoiceRouting.recipients_for(trusted_speaker, table, d["kind"], prox_range, max_fanout)
	var peers: Array[int] = []
	for id in ids:
		peers.append((table[id] as Dictionary)["voice_peer"])
	var out := VoicePacket.encode(trusted_speaker, d["kind"], d["seq"], d["frame"])
	return {"recipients": peers, "frame": out}
