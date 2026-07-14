class_name WeaponPredictor
extends RefCounted
## Client-side predicted weapon state (mag + reload) mirroring server _resolve_fires gating, so
## the HUD ammo matches authority deterministically. reconcile() snaps to SELF_STATE. C1: mag only
## (sim reload refills full mag; finite reserve is a later combat-depth item).

var weapon: int = Weapon.AR
var mag: int = 30
var reserve: int = 180   # spare-bullet pool (reserve-ammo economy); reconciled from SELF_STATE
var spare_mags: Array = []   # spare-mag FIFO round counts (M2 ammo); reconciled from SELF_STATE
var _reload_fast: bool = false
var reloading: bool = false
var fire_mode: int = Weapon.MODE_AUTO   # selected fire mode (HUD + local-tracer gating; sent via SET_FIRE_MODE)
var fire_mode_by_weapon: Dictionary = {}   # weapon_id -> last-selected mode; persists across swaps + respawns
var _reload_done_tick: int = 0
var _last_fire_tick: int = -100000
var _shot_index: int = 0                # shots fired in the current trigger hold (gates SEMI/BURST)
var _was_firing: bool = false           # previous-tick trigger state, for press-edge detection

func set_weapon(w: int) -> void:
	weapon = w
	mag = int(Weapon.get_def(w)["mag_size"])
	reserve = Weapon.reserve_ammo(w)
	spare_mags = Weapon.spawn_mags(w)
	# Restore this weapon's remembered fire mode (default the first time we hold it), so swapping away
	# and back — or respawning — keeps the selection instead of snapping back to AUTO.
	fire_mode = int(fire_mode_by_weapon.get(w, Weapon.default_mode(w)))
	_shot_index = 0

## Advance to the next fire mode in the weapon's allowed list (wraps). No-op for single-mode
## weapons. Returns the new mode. The caller sends SET_FIRE_MODE so the server's gating matches.
func cycle_fire_mode() -> int:
	var modes: Array = Weapon.get_def(weapon)["fire_modes"]
	if modes.size() <= 1:
		return fire_mode
	var i := modes.find(fire_mode)
	fire_mode = int(modes[(i + 1) % modes.size()]) if i >= 0 else int(modes[0])
	fire_mode_by_weapon[weapon] = fire_mode   # remember the choice for this weapon
	return fire_mode

## Returns true if a shot fired this tick. Mirrors server gating (cadence, mag, reload, sprint) AND
## the fire mode (SEMI = one per press, BURST = burst_count per press, AUTO = continuous) so the
## locally-predicted tracer matches authority instead of spamming on semi/burst weapons.
func step(tick: int, firing: bool, sprinting: bool, drop_shoot: bool) -> bool:
	if reloading and tick >= _reload_done_tick:
		reloading = false
		# M2 ammo: FIFO tap-reload banks the current partial + loads the next non-empty spare; a fast
		# reload already dropped the current mag at begin_reload, so it just loads the next spare.
		var res: Array = Weapon.load_next(spare_mags) if _reload_fast else Weapon.reload_swap(mag, spare_mags)
		if bool(res[2]):
			mag = int(res[0])
			spare_mags = res[1]
		reserve = _sum_spare()
		_reload_fast = false
	var rising := firing and not _was_firing
	_was_firing = firing
	if not firing:
		_shot_index = 0   # trigger released — next press starts a fresh burst/semi shot
		return false
	if reloading or mag <= 0 or sprinting or drop_shoot:
		return false
	if rising:
		_shot_index = 0
	var interval_ticks := Weapon.fire_interval(weapon) / SimLoop.DT
	if float(tick - _last_fire_tick) < interval_ticks:
		return false
	var burst := int(Weapon.get_def(weapon).get("burst_count", Weapon.DEFAULT_BURST))
	if not Weapon.fire_allowed(fire_mode, _shot_index, burst):
		return false
	_last_fire_tick = tick
	_shot_index += 1
	mag -= 1
	return true

func begin_reload(tick: int, fast: bool = false) -> void:
	if reloading or mag >= int(Weapon.get_def(weapon)["mag_size"]) or not Weapon.has_loadable_spare(spare_mags):
		return
	reloading = true
	_reload_fast = fast
	var base := int(round(float(Weapon.get_def(weapon)["reload_secs"]) / SimLoop.DT))
	_reload_done_tick = tick + (int(round(base * 0.75)) if fast else base)
	if fast and mag > 0:
		mag = 0   # fast reload drops the current mag immediately (server spawns the recoverable pickup)

func reload_remaining(tick: int) -> int:
	return maxi(0, _reload_done_tick - tick) if reloading else 0

func _sum_spare() -> int:
	var s := 0
	for m in spare_mags:
		s += int(m)
	return s

## Snap the reserve pool to the authoritative SELF_STATE value. Reserve only changes on reload /
## resupply / respawn (never per-shot), so unlike mag there's no prediction lead to preserve —
## just take authority when it's present (a pre-6 server sends -1, which we ignore).
func reconcile_reserve(auth_reserve: int) -> void:
	if auth_reserve >= 0:
		reserve = auth_reserve

## Snap the spare-mag FIFO to authority (SELF_STATE). Like reserve, spares only change on
## reload / resupply / respawn (never per-shot), so just take authority when present.
func reconcile_spare_mags(auth: Array) -> void:
	spare_mags = auth.duplicate()

func reconcile(auth_mag: int, auth_reloading: bool, auth_reload_remaining: int, now_tick: int = 0) -> void:
	reloading = auth_reloading
	if auth_reloading:
		mag = auth_mag
		_reload_done_tick = now_tick + auth_reload_remaining
	elif (mag <= 0 and auth_mag > 0) or absi(auth_mag - mag) >= 3:
		# Snap on a real divergence (reload refill / drift >= 3) OR when we've predicted ourselves dry
		# but authority still has rounds — otherwise a small over-prediction could lock out firing.
		mag = auth_mag
	# else: small diff is just the prediction leading the lagged server mag by the in-flight shots;
	# trust the local prediction so the counter doesn't jitter up/down every reconcile.
