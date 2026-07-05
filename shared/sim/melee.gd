class_name Melee
extends Object
## Pure melee geometry (M5.5-P3): reach + rear-arc back-stab + nearest-frontal-target selection.
## Server applies damage; these are side-effect-free. See docs/specs/combat-depth-2.md §3.

const MELEE_RANGE := 2.2   # forgiving knife-lunge reach (was 1.5 — too tight for a lag-comp swing at a mover)
# Rear arc for the instant-kill back-stab. 120 deg (was 60) so sneaking behind a strafing/turning
# target still reads as a back-stab — anything clearly behind the victim's facing instant-kills; only
# near-perpendicular (>60 deg off dead-behind) and frontal hits fall through to the 2-hit knife path.
const BACKSTAB_ARC_DEG := 120.0

static func in_reach(attacker_pos: Vector3, target_pos: Vector3) -> bool:
	return attacker_pos.distance_to(target_pos) <= MELEE_RANGE

## `rel` is (attacker_pos - target_pos): where the attacker stands relative to the target. A
## back-stab requires the attacker to be within BACKSTAB_ARC of directly behind the target's facing.
static func is_backstab(target_yaw: float, rel: Vector3) -> bool:
	var back := Vector3(-sin(target_yaw), 0.0, -cos(target_yaw))   # opposite the target's forward
	var flat := Vector3(rel.x, 0.0, rel.z)
	if flat.length() < 0.001:
		return false
	return rad_to_deg(back.angle_to(flat.normalized())) <= BACKSTAB_ARC_DEG * 0.5

## Nearest enemy within reach and within a frontal cone of the attacker; 0 if none.
static func best_target(attacker: Dictionary, enemies: Array) -> int:
	var fwd := Vector3(sin(attacker["yaw"]), 0.0, cos(attacker["yaw"]))
	var best := 0
	var best_d := MELEE_RANGE + 1.0
	for e in enemies:
		if int(e["team"]) == int(attacker["team"]):
			continue
		var to: Vector3 = e["pos"] - attacker["pos"]
		var d := to.length()
		if d > MELEE_RANGE or d < 0.001:
			continue
		if Vector3(to.x, 0, to.z).normalized().dot(fwd) < 0.3:   # not in front
			continue
		if d < best_d:
			best_d = d
			best = int(e["id"])
	return best
