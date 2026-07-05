class_name TickLead
extends RefCounted
## Client input-clock tick-lead management (docs/specs/netcode-tick-lead.md). The server reports
## its per-client InputBuffer depth on each SELF_STATE; this accumulator nudges WHEN the client
## produces input frames — hold one (repeats 0) when the buffer runs too full, emit an extra
## (repeats 2) when it runs too shallow — so the buffer converges to TARGET and the reconcile
## replay length stops wandering (the ~1 Hz movement micro-snap). Standard adaptive tick-sync;
## no gameplay rule logic moves to the client (AGENTS.md §7) — this only paces intent sampling.

const TARGET := 2      # frames (~66 ms at 30 Hz): 1 above empty, well under InputBuffer.MAX_DEPTH=4
const GAIN := 0.05     # phase per depth-error unit per sample — slow, below perceptual threshold

var _phase := 0.0      # fractional pending correction; +-1.0 converts to one whole-frame adjust

# Telemetry for the [client-dbg] line / feel-gate meter.
var holds := 0         # frames held (buffer was too full)
var extras := 0        # extra frames emitted (buffer was too shallow)
var last_depth := -1   # most recent reported depth (-1: none yet)

## Feed one authoritative buffer-depth sample (SELF_STATE trailing byte). Error is clamped to
## +-1 so a single outlier sample can never swing the phase by more than GAIN.
func on_depth(depth: int) -> void:
	last_depth = depth
	_phase += clampf(float(depth - TARGET), -1.0, 1.0) * GAIN

## How many input frames to produce this physics frame: 0 = hold (let the server drain the
## surplus), 1 = normal, 2 = catch up. At most one whole-frame adjust per call.
func frame_repeats() -> int:
	if _phase >= 1.0:
		_phase -= 1.0
		holds += 1
		return 0
	if _phase <= -1.0:
		_phase += 1.0
		extras += 1
		return 2
	return 1

## Drop accumulated phase (deploy/respawn: the buffer refills from scratch).
func reset() -> void:
	_phase = 0.0
