class_name VoicePlayback
extends Node
## NOTE: the decoder + AudioStreamGenerator playback shell (feed/_process, jitter+OpusVoiceDecoder wiring) is DEFERRED to Phase 3 integration; this file currently holds only the pure, tested route() decision.
## Decodes per-speaker voice and plays it: proximity → AudioStreamPlayer3D routed through
## the M7 audio engine (distance/occlusion), squad → flat 2D. route() is the pure decision;
## the decoder + AudioStreamGenerator wiring is deferred to Phase 3 integration.

## PURE: returns {play, bus, spatial} for an inbound frame from speaker_id.
static func route(kind: int, speaker_id: int, muted: Dictionary) -> Dictionary:
	if muted.has(speaker_id):
		return {"play": false, "bus": "Voice", "spatial": false}
	return {
		"play": true,
		"bus": "Voice",
		"spatial": kind == VoicePacket.KIND_PROXIMITY,
	}
