class_name RiotShield
extends Object
## Pure Support Riot Shield rules: the frontal-arc bullet block + the shield-HP pool constants.
## Geometry matches DamageDir.bearing's atan2(dx,dz) convention (yaw 0 faces +Z).

const SHIELD_HP := 300              # full shield pool (server-owned)
const SHIELD_ARC_DEG := 75.0        # half-angle of the protected frontal arc (150 deg cover)
const SHIELD_SPEED_MULT := 0.7      # move-speed multiplier while shield up
const SHIELD_BREAK_TICKS := 150     # forced-down lockout armed on a full break (~5 s); the pool
                                    # never regenerates, so a broken shield stays down for the life
                                    # regardless (only respawn or a Support resupply re-arm it).

## True when a hit arriving from world-space bearing `bearing` lands within the shield's
## protected frontal arc while the bearer faces `facing_yaw`. Both angles use DamageDir.bearing's
## atan2(dx,dz) convention (yaw 0 faces +Z); wrapf handles the +/-PI wrap so directly-behind hits
## (bearing == facing_yaw + PI) are never mistaken for frontal.
static func blocks(facing_yaw: float, bearing: float) -> bool:
	var d: float = wrapf(bearing - facing_yaw, -PI, PI)
	return absf(d) <= deg_to_rad(SHIELD_ARC_DEG)

## True when the incoming hit is the kind of small-arms fire the shield actually stops:
## a bullet (Revive.Source.BULLET) that is not a back-stab. Explosive/blast, fall, and
## back-stab damage all bypass the shield outright (server applies them regardless of facing).
static func is_small_arms(source: int, backstab: bool) -> bool:
	return source == Revive.Source.BULLET and not backstab
