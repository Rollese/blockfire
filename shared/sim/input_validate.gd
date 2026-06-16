class_name InputValidate
extends Object
## Anti-cheat Layer 2: server-side input bound-checks at the sim boundary. CLAMP, don't reject
## (rejecting risks desync); callers record anomalies via the returned/flagged values. Rules live
## in shared/ so they're deterministic + unit-testable. See docs/specs/vehicles.md §7 / ADR-0004.

static func clamp_axis(x: float) -> float:
	return clampf(x, -1.0, 1.0)

## Clamp each axis to [-1,1] and renormalize if the vector exceeds unit length (matches Pawn.step).
static func sanitize_move(mx: float, my: float) -> Vector2:
	var v := Vector2(clamp_axis(mx), clamp_axis(my))
	if v.length() > 1.0:
		v = v.normalized()
	return v

## True if the per-tick yaw/pitch change is within max_rate (radians/tick). Yaw wraps via angle diff.
static func view_rate_ok(prev_yaw: float, yaw: float, prev_pitch: float, pitch: float, max_rate: float) -> bool:
	var dy := absf(wrapf(yaw - prev_yaw, -PI, PI))
	var dp := absf(pitch - prev_pitch)
	return dy <= max_rate and dp <= max_rate
