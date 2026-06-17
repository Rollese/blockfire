class_name AudioMix
extends Object
## Pure spatial-audio math: distance attenuation, occlusion muffle, suppression muffle, crack/bang
## delay. Engine-object-free so it runs headless. Presentation-only (AGENTS.md §7) — reads positions
## and replicated scalars, never gameplay authority.

const OCCLUSION_MIN_GAIN := 0.35    # fully-blocked sources are quieter, never silent
const OPEN_CUTOFF_HZ := 20000.0     # no low-pass (full bandwidth)
const MUFFLED_CUTOFF_HZ := 600.0    # fully-occluded low-pass
const SUPPRESS_CUTOFF_HZ := 1200.0  # listener-global muffle when fully suppressed
const SUPPRESS_DUCK_GAIN := 0.7     # global volume duck when fully suppressed
const SUPPRESS_THRESHOLD := 0.25    # mirrors M5.5 SUPPRESS_THRESHOLD
const SPEED_OF_SOUND := 343.0       # m/s
const TICKS_PER_SEC := 30.0
const CRACK_BANG_MIN_RANGE := 25.0  # below this, crack+bang collapse to one report

## Inverse-distance attenuation with a hard max-audible cutoff. gain in [0,1].
static func distance_gain(d: float, unit_size: float, max_distance: float) -> float:
	if max_distance > 0.0 and d >= max_distance:
		return 0.0
	if d <= unit_size:
		return 1.0
	return unit_size / d

## Occlusion volume factor: 1.0 clear .. OCCLUSION_MIN_GAIN fully blocked. coverage in [0,1].
static func occlusion_gain(coverage: float) -> float:
	return lerpf(1.0, OCCLUSION_MIN_GAIN, clampf(coverage, 0.0, 1.0))

## Occlusion low-pass cutoff: open .. muffled. coverage in [0,1].
static func occlusion_cutoff(coverage: float) -> float:
	return lerpf(OPEN_CUTOFF_HZ, MUFFLED_CUTOFF_HZ, clampf(coverage, 0.0, 1.0))

## Listener-global suppression low-pass; no-op below threshold. s in [0,1].
static func suppression_cutoff(s: float) -> float:
	if s < SUPPRESS_THRESHOLD:
		return OPEN_CUTOFF_HZ
	var t := smoothstep(SUPPRESS_THRESHOLD, 1.0, clampf(s, 0.0, 1.0))
	return lerpf(OPEN_CUTOFF_HZ, SUPPRESS_CUTOFF_HZ, t)

## Listener-global suppression volume duck; no-op below threshold. s in [0,1].
static func suppression_duck(s: float) -> float:
	if s < SUPPRESS_THRESHOLD:
		return 1.0
	var t := smoothstep(SUPPRESS_THRESHOLD, 1.0, clampf(s, 0.0, 1.0))
	return lerpf(1.0, SUPPRESS_DUCK_GAIN, t)

## Ticks between the muzzle bang arriving after the supersonic crack. 0 under CRACK_BANG_MIN_RANGE.
static func bang_delay_ticks(distance: float) -> int:
	if distance < CRACK_BANG_MIN_RANGE:
		return 0
	return int(round(distance / SPEED_OF_SOUND * TICKS_PER_SEC))

## Combine distance gain + occlusion into final {gain, cutoff}. def_cutoff is the per-def low-pass
## (OPEN if none). Final cutoff is the darker (min) of occlusion and def.
static func combine(dist_gain: float, coverage: float, def_cutoff: float) -> Dictionary:
	return {
		"gain": dist_gain * occlusion_gain(coverage),
		"cutoff": minf(occlusion_cutoff(coverage), def_cutoff),
	}
