class_name Degrade
extends RefCounted
## Pure adaptive snapshot-degradation ladder (M8-P3). The server samples windowed `tick_mean` once
## per telemetry window and climbs/descends a fixed ladder with hysteresis: over HIGH_MS it sheds one
## step (longer send stride + fewer distant enemies replicated), under LOW_MS it restores one step, in
## the band it holds (no per-window thrash). **Level 0 == the static baseline snapshot params**, so a
## server that never breaches budget behaves exactly as before this change.
## See docs/specs/m8-hardening-ops.md §P3.

const HIGH_MS := 30.0   # climb a step when windowed tick_mean exceeds this (approaching the 33.3ms budget)
const LOW_MS := 26.0     # descend a step when it recovers below this (hysteresis band 26..30ms)

# Ladder rows: [snapshot_stride, max_enemy_snapshot]. Index 0 mirrors server_main's static consts
# (SNAPSHOT_STRIDE=2, MAX_ENEMY_SNAPSHOT=24). Higher rows shed load: send less often, drop distant enemies.
const LEVELS := [[2, 24], [3, 18], [4, 12]]

static func max_level() -> int:
	return LEVELS.size() - 1

## Next degradation level from the current one given the windowed mean tick time. Hysteresis:
## climbs only above `high_ms`, descends only below `low_ms`, holds in between. Clamped to the ladder.
## Thresholds are parameters (the server exposes CLI overrides) with the consts as defaults.
static func next_level(tick_mean_ms: float, level: int, high_ms: float = HIGH_MS, low_ms: float = LOW_MS) -> int:
	var lv := clampi(level, 0, max_level())
	if tick_mean_ms > high_ms and lv < max_level():
		return lv + 1
	if tick_mean_ms < low_ms and lv > 0:
		return lv - 1
	return lv

static func stride_for(level: int) -> int:
	return int(LEVELS[clampi(level, 0, max_level())][0])

static func enemy_cap_for(level: int) -> int:
	return int(LEVELS[clampi(level, 0, max_level())][1])
