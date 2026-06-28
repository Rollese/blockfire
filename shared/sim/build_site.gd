class_name BuildSite
extends Object
## Pure progressive-construction math for M12-P2 cooperative shovel building. A placed fortification
## starts as a *build site* at progress 0 and accrues `build_progress` while enough eligible builders
## (in range + facing + holding the shovel) work it; small pieces need 1 builder, large pieces need
## >=2. On completion the server hands the site to StructureStore.place (a normal M4 structure). All
## rules live here so server authority and any future client prediction can't diverge (AGENTS.md §5).

const SHOVEL_RANGE := 4.0                 # m: a builder must be within this of the site centre
const SHOVEL_FACING_DOT := 0.35           # must be roughly facing the site (cos of the half-angle)
const SHOVEL_RATE_PER_BUILDER := 70.0     # build_cost units per second per builder
const MAX_BUILDERS_PER_SITE := 4          # builders past this add nothing (anti-zerg)
const BUILD_SITE_DECAY_TICKS := 450       # 15 s @ 30 Hz of no work -> an unfinished site is freed
const SHOVEL_DISMANTLE_RATE := 28.0       # progress/sec/builder removed when digging an enemy site

## New progress after one tick. No advance unless `builders >= min_builders` (the cooperation gate);
## scales with builders up to MAX_BUILDERS_PER_SITE; clamps at build_cost.
static func progress_step(progress: float, build_cost: int, builders: int, min_builders: int, dt: float) -> float:
	if builders < min_builders or builders <= 0:
		return progress
	var n := mini(builders, MAX_BUILDERS_PER_SITE)
	return minf(progress + SHOVEL_RATE_PER_BUILDER * float(n) * dt, float(build_cost))

## New (reduced) progress when enemies dig down an under-construction site; floors at 0.
static func dismantle_step(progress: float, builders: int, dt: float) -> float:
	if builders <= 0:
		return progress
	var n := mini(builders, MAX_BUILDERS_PER_SITE)
	return maxf(progress - SHOVEL_DISMANTLE_RATE * float(n) * dt, 0.0)

static func is_complete(progress: float, build_cost: int) -> bool:
	return progress >= float(build_cost)

## A builder counts toward a site iff within SHOVEL_RANGE and roughly facing it.
static func eligible(builder_pos: Vector3, builder_fwd: Vector3, site_center: Vector3) -> bool:
	var to := site_center - builder_pos
	var d := to.length()
	if d > SHOVEL_RANGE:
		return false
	if d < 0.01:
		return true
	return builder_fwd.normalized().dot(to / d) >= SHOVEL_FACING_DOT

static func decayed(now_tick: int, last_work_tick: int) -> bool:
	return (now_tick - last_work_tick) >= BUILD_SITE_DECAY_TICKS
