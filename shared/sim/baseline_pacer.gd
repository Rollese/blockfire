class_name BaselinePacer
extends Object
## Paces structure-baseline replication: picks which not-yet-known regions to send a client THIS tick
## so a fresh join / large move doesn't flood one tick with a whole dense map's worth of pieces. The
## structures are static, so streaming them in over a handful of ticks (nearest-first, ~0.5s on the
## densest map) is imperceptible and keeps the per-tick snapshot cost bounded (mirrors SNAPSHOT_STRIDE
## for entity sends). Pure — no I/O, no store access. See server_main._sync_structure_baselines.

## candidates: Array of {region: Vector2i, dist2: float, pieces: int} — the unknown, NON-empty regions
## in the client's interest range. budget: max cumulative pieces to send this tick.
## Returns the nearest-first subset whose cumulative `pieces` stays within `budget`, but ALWAYS at
## least one region when any exist (so a single region larger than the whole budget still streams,
## guaranteeing forward progress). Order is nearest-first so on-screen structures arrive first.
static func pick(candidates: Array, budget: int) -> Array:
	var sorted := candidates.duplicate()
	sorted.sort_custom(func(a, b): return float(a["dist2"]) < float(b["dist2"]))
	var out: Array = []
	var acc := 0
	for c in sorted:
		var pieces := int(c["pieces"])
		if not out.is_empty() and acc + pieces > budget:
			break
		out.append(c)
		acc += pieces
	return out
