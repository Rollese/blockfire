class_name Suppress
extends Object
## Pure suppression math (M5.5-P2). A 0..1 scalar per pawn raised by nearby incoming fire and
## decaying each tick; above a threshold it widens the pawn's shot spread (gameplay-affecting,
## never lag-comp or authority). Replicated as one byte for the M7 screen FX. See spec §2.

const SUPPRESS_RADIUS := 2.5          # m: a bullet passing within this of a pawn suppresses it
const SUPPRESS_PER_NEARMISS := 0.15   # max add for a dead-on near-miss (scaled by closeness)
const SUPPRESS_DECAY := 0.04          # per-tick decay toward 0
const SUPPRESS_THRESHOLD := 0.25      # below this, no spread penalty
const MAX_SPREAD_DEG := 2.5           # spread penalty at full (1.0) suppression

## Add suppression for a near-miss at `dist` metres (closer = more), clamped to [0,1].
static func accrue(current: float, dist: float) -> float:
	if dist >= SUPPRESS_RADIUS:
		return current
	var closeness := 1.0 - (dist / SUPPRESS_RADIUS)
	return clampf(current + SUPPRESS_PER_NEARMISS * closeness, 0.0, 1.0)

## Decay one tick toward zero (floored at 0).
static func decay(current: float) -> float:
	return maxf(0.0, current - SUPPRESS_DECAY)

## Extra spread in degrees from the current suppression (0 below threshold; ramps to MAX at 1.0).
static func spread_penalty_deg(suppression: float) -> float:
	if suppression < SUPPRESS_THRESHOLD:
		return 0.0
	var t := (suppression - SUPPRESS_THRESHOLD) / (1.0 - SUPPRESS_THRESHOLD)
	return MAX_SPREAD_DEG * clampf(t, 0.0, 1.0)
