class_name Quantize
extends Object
## Lossy fixed-point encoders for the wire. Positions to millimetres (i32),
## angles to u16 (65536 / 360°). See docs/specs/m1-netcode-core.md.

const POS_SCALE := 1000.0          # 1 mm resolution
const ANGLE_SCALE := 65536.0 / TAU

static func enc_pos(meters: float) -> int:
	return roundi(meters * POS_SCALE)

static func dec_pos(units: int) -> float:
	return float(units) / POS_SCALE

static func enc_angle(rad: float) -> int:
	return roundi(fposmod(rad, TAU) * ANGLE_SCALE) & 0xFFFF

static func dec_angle(u: int) -> float:
	return float(u) / ANGLE_SCALE
