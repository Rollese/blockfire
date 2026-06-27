class_name RevivePulse
extends Object
## Pure vertical-bob for the downed-teammate revive marker (M7, view-only — AGENTS.md §7). A friendly
## who is DBNO keeps a marker (so squadmates can find + revive them), but it bobs and is re-tinted so
## it stands out from the steady blue alive-friendly markers. Time-based so it's frame-rate-independent.

const AMP := 0.22     # m of vertical travel
const HZ := 1.8       # bobs per second

## Returns a [0, AMP] vertical offset; (1-cos)/2 so it starts at rest (0) and rises smoothly.
static func bob(now: float) -> float:
	return AMP * 0.5 * (1.0 - cos(now * TAU * HZ))
