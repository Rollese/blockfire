class_name FootstepCadence
extends RefCounted
## Pure, deterministic footstep cadence: a pawn fires a footstep every time it has travelled one
## "stride" along the ground. View-only presentation feedback (AGENTS.md §7) — drives a dust puff
## (renderer) and a spatial footstep sound (audio). No wire/gameplay effect.
##
## Stateless except for a per-pawn distance accumulator the caller threads back through advance().
## The caller owns one accumulator per pawn (the local predicted pawn + each visible remote) and
## feeds the ground distance moved each render frame.

const MIN_STEP_SPEED := 0.6      # m/s — below this the pawn reads as standing; no steps, drain accum
const SPRINT_REF_SPEED := 7.0    # m/s — speed that reads as a full-intensity sprint footfall
const MIN_INTENSITY := 0.35      # even a slow walk kicks a small puff / quiet step
const MAX_FRAME_DIST := 3.0      # m in one frame -> teleport/respawn: reset the accumulator, don't fire

## Stride length (metres between footfalls) for a stance. PRONE crawls silently (0 -> never fires).
static func stride_for(stance: int) -> float:
	match stance:
		Stance.CROUCH: return 1.4
		Stance.PRONE:  return 0.0
		_:             return 2.2   # STAND

## Advance one pawn's footstep accumulator by `dist` metres of ground travel this frame.
## Returns {accum, fired, intensity}: `fired` true on a footfall; `intensity` in [MIN_INTENSITY, 1].
static func advance(accum: float, dist: float, speed: float, stance: int, grounded: bool) -> Dictionary:
	var stride := stride_for(stance)
	# Not stepping: airborne, crawling/prone, or essentially stationary. Drain the accumulator so a
	# stop-then-go pawn doesn't immediately fire from leftover travel.
	if not grounded or stride <= 0.0 or speed < MIN_STEP_SPEED:
		return {"accum": 0.0, "fired": false, "intensity": 0.0}
	# Teleport / respawn jump: ignore the bogus distance and reset.
	if dist >= MAX_FRAME_DIST or dist < 0.0:
		return {"accum": 0.0, "fired": false, "intensity": 0.0}
	var a := accum + dist
	if a < stride:
		return {"accum": a, "fired": false, "intensity": 0.0}
	# Footfall. Keep the remainder so cadence stays phase-correct across frames.
	var intensity := clampf(speed / SPRINT_REF_SPEED, MIN_INTENSITY, 1.0)
	return {"accum": a - stride, "fired": true, "intensity": intensity}
