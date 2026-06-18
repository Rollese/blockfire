class_name ServerVoice
extends RefCounted
## Pure helper: turn the tick's per-player rows into the VoiceRoutingTable payload.
## Keeps server_main's per-tick publish a one-liner over tested logic.

static func build_route_table(rows: Array) -> Dictionary:
	var t := {}
	for r in rows:
		var row: Dictionary = r
		t[row["id"]] = {
			"pos": row["pos"], "team": row["team"], "squad": row["squad"],
			"voice_peer": row["voice_peer"], "alive": row["alive"],
		}
	return t
