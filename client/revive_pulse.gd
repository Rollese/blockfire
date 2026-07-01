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

# Bleed-out urgency (M7 DOWNED_LIST): as a downed teammate nears the bleed-out floor (frac 1 -> 0)
# the marker bobs FASTER and HIGHER, so at a glance you triage who to revive first. A self-bandaged
# (halted) pawn is stabilised — it holds the calm rate regardless of frac.
const HZ_URGENT := 4.6     # bob rate the instant before bleed-out
const AMP_URGENT := 0.34   # bigger travel near death

## Bob frequency ramps HZ (calm, frac=1) -> HZ_URGENT (frac=0). Halted holds the calm rate.
static func hz_for(frac: float, halted: bool = false) -> float:
	if halted:
		return HZ
	return lerpf(HZ_URGENT, HZ, clampf(frac, 0.0, 1.0))

## Urgency bob: both amplitude and frequency grow as the pawn nears bleed-out (frac -> 0).
static func urgency_bob(now: float, frac: float, halted: bool = false) -> float:
	var f := clampf(frac, 0.0, 1.0)
	var amp := lerpf(AMP_URGENT, AMP, f)   # bigger near death
	if halted:
		amp = AMP
	return amp * 0.5 * (1.0 - cos(now * TAU * hz_for(f, halted)))
