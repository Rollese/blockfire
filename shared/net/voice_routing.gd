class_name VoiceRouting
extends RefCounted
## Pure recipient selection for a voice frame. table: { player_id: RouteEntry }
## RouteEntry := {pos: Vector3, team: int, squad: int, voice_peer: int, alive: bool}.
## Deterministic, no engine objects → fully headless-testable.

static func recipients_for(speaker_id: int, table: Dictionary, kind: int,
		prox_range: float, max_fanout: int) -> Array:
	if not table.has(speaker_id):
		return []
	var spk: Dictionary = table[speaker_id]
	var out: Array = []
	if kind == VoicePacket.KIND_SQUAD:
		for id in table:
			if id == speaker_id:
				continue
			var e: Dictionary = table[id]
			if e["voice_peer"] != 0 and e["team"] == spk["team"] and e["squad"] == spk["squad"]:
				out.append(id)
		return out
	# proximity: in-range, alive, voice-connected; nearest-first; capped.
	var cands: Array = []
	var spos: Vector3 = spk["pos"]
	for id in table:
		if id == speaker_id:
			continue
		var e: Dictionary = table[id]
		if not e["alive"] or e["voice_peer"] == 0:
			continue
		var d: float = (e["pos"] as Vector3).distance_to(spos)
		if d <= prox_range:
			cands.append([d, id])
	cands.sort_custom(func(a, b): return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	for i in range(mini(max_fanout, cands.size())):
		out.append(cands[i][1])
	return out
