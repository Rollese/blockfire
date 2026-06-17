class_name WeaponPredictor
extends RefCounted
## Client-side predicted weapon state (mag + reload) mirroring server _resolve_fires gating, so
## the HUD ammo matches authority deterministically. reconcile() snaps to SELF_STATE. C1: mag only
## (sim reload refills full mag; finite reserve is a later combat-depth item).

var weapon: int = Weapon.AR
var mag: int = 30
var reloading: bool = false
var _reload_done_tick: int = 0
var _last_fire_tick: int = -100000

func set_weapon(w: int) -> void:
	weapon = w
	mag = int(Weapon.get_def(w)["mag_size"])

## Returns true if a shot fired this tick. Mirrors server gating (cadence, mag, reload, sprint).
func step(tick: int, firing: bool, sprinting: bool, drop_shoot: bool) -> bool:
	if reloading and tick >= _reload_done_tick:
		reloading = false
		mag = int(Weapon.get_def(weapon)["mag_size"])
	if not firing or reloading or mag <= 0 or sprinting or drop_shoot:
		return false
	var interval_ticks := Weapon.fire_interval(weapon) / SimLoop.DT
	if float(tick - _last_fire_tick) < interval_ticks:
		return false
	_last_fire_tick = tick
	mag -= 1
	return true

func begin_reload(tick: int) -> void:
	if reloading or mag >= int(Weapon.get_def(weapon)["mag_size"]):
		return
	reloading = true
	_reload_done_tick = tick + int(round(float(Weapon.get_def(weapon)["reload_secs"]) / SimLoop.DT))

func reload_remaining(tick: int) -> int:
	return maxi(0, _reload_done_tick - tick) if reloading else 0

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
