extends TestCase

func _wp() -> WeaponPredictor:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)   # mag_size 30
	return wp

func test_fire_decrements_mag_respecting_cadence() -> void:
	var wp := _wp()
	# one fire on tick 0 consumes a round; a fire on the very next tick is gated by cadence.
	assert_true(wp.step(0, true, false, false), "first shot fires")
	assert_eq(wp.mag, 29)
	assert_false(wp.step(1, true, false, false), "next-tick shot gated by RPM cadence")
	assert_eq(wp.mag, 29)

func test_fire_mode_persists_per_weapon_across_swaps() -> void:
	# C1/E1: fire mode reset to AUTO after swapping to the pistol and back. It must be remembered
	# per weapon so a selection survives a weapon swap (and, via the same map, a respawn).
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	assert_eq(wp.fire_mode, Weapon.MODE_AUTO, "AR defaults to AUTO (first in its list)")
	assert_eq(wp.cycle_fire_mode(), Weapon.MODE_SEMI, "V cycles AUTO -> SEMI")
	wp.set_weapon(Weapon.PISTOL)   # swap away
	wp.set_weapon(Weapon.AR)       # swap back
	assert_eq(wp.fire_mode, Weapon.MODE_SEMI, "AR restores its remembered SEMI, not the AUTO default")

func test_fire_mode_defaults_for_never_cycled_weapon() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.SMG)
	assert_eq(wp.fire_mode, Weapon.default_mode(Weapon.SMG), "unseen weapon uses its default mode")

func test_no_fire_while_sprinting_or_empty() -> void:
	var wp := _wp()
	assert_false(wp.step(0, true, true, false), "sprint blocks fire")
	wp.mag = 0
	assert_false(wp.step(100, true, false, false), "empty mag blocks fire")

func test_reload_refills_after_duration() -> void:
	var wp := _wp(); wp.mag = 5
	wp.begin_reload(0)
	assert_true(wp.reloading)
	var done := int(round(float(Weapon.get_def(Weapon.AR)["reload_secs"]) / SimLoop.DT))
	wp.step(done, false, false, false)   # tick at/after completion
	assert_false(wp.reloading)
	assert_eq(wp.mag, int(Weapon.get_def(Weapon.AR)["mag_size"]))

func test_reconcile_snaps_to_authoritative() -> void:
	var wp := _wp(); wp.mag = 29
	wp.reconcile(20, false, 0)
	assert_eq(wp.mag, 20, "predicted mag snaps to SELF_STATE mag")

func test_reconcile_to_reloading_sets_remaining() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.AR)
	# server says: reloading, 30 ticks remaining, as of tick 100. mag irrelevant here.
	wp.reconcile(0, true, 30, 100)
	assert_true(wp.reloading)
	assert_eq(wp.reload_remaining(100), 30, "remaining reflects authoritative reload time")
	# a step BEFORE completion must NOT finish the reload (no instant-fill flash)
	wp.step(110, false, false, false)
	assert_true(wp.reloading, "still reloading at tick 110 (< done at 130)")
	# at/after completion it finishes
	wp.step(130, false, false, false)
	assert_false(wp.reloading, "reload completes at its authoritative done tick")


func test_fire_mode_defaults_to_weapon_default_and_resets_on_swap() -> void:
	var wp := _wp()
	assert_eq(wp.fire_mode, Weapon.default_mode(Weapon.AR), "AR starts in its default mode")
	wp.cycle_fire_mode()
	assert_true(wp.fire_mode != Weapon.default_mode(Weapon.AR), "cycled away from default")
	wp.set_weapon(Weapon.SMG)
	assert_eq(wp.fire_mode, Weapon.default_mode(Weapon.SMG), "weapon swap resets to the new default")


func test_cycle_fire_mode_walks_allowed_modes_and_wraps() -> void:
	var wp := _wp()   # AR fire_modes = [AUTO, SEMI, BURST]
	var modes: Array = Weapon.get_def(Weapon.AR)["fire_modes"]
	var start: int = wp.fire_mode
	var seen: Array = [start]
	for _i in range(modes.size() - 1):
		seen.append(wp.cycle_fire_mode())
	assert_eq(wp.cycle_fire_mode(), start, "wraps back to the starting mode after a full cycle")
	for m in modes:
		assert_true(m in seen, "every allowed mode is reachable by cycling")


func test_single_mode_weapon_cycle_is_noop() -> void:
	var wp := WeaponPredictor.new(); wp.set_weapon(Weapon.DMR)   # fire_modes = [SEMI]
	assert_eq(wp.fire_mode, Weapon.MODE_SEMI)
	assert_eq(wp.cycle_fire_mode(), Weapon.MODE_SEMI, "single-mode weapon stays put")


func test_semi_fires_once_per_trigger_press() -> void:
	var wp := _wp(); wp.fire_mode = Weapon.MODE_SEMI
	# Hold the trigger across many cadence-spaced ticks: SEMI fires only the first.
	assert_true(wp.step(0, true, false, false), "first SEMI shot fires")
	assert_false(wp.step(3, true, false, false), "held SEMI does not auto-repeat")
	assert_false(wp.step(6, true, false, false), "still gated while held")
	# Release, then press again -> fires once more.
	wp.step(7, false, false, false)
	assert_true(wp.step(9, true, false, false), "re-press fires the next SEMI shot")


func test_burst_fires_burst_count_then_stops_until_release() -> void:
	var wp := _wp(); wp.fire_mode = Weapon.MODE_BURST
	var burst: int = int(Weapon.get_def(Weapon.AR)["burst_count"])
	var fired := 0
	var tick := 0
	for _i in range(burst + 3):   # hold well past the burst length
		if wp.step(tick, true, false, false):
			fired += 1
		tick += 3   # space beyond the RPM cadence so only the mode gates
	assert_eq(fired, burst, "a held burst fires exactly burst_count shots")


func test_auto_fires_continuously_at_cadence() -> void:
	var wp := _wp(); wp.fire_mode = Weapon.MODE_AUTO
	var fired := 0
	var tick := 0
	for _i in range(4):
		if wp.step(tick, true, false, false):
			fired += 1
		tick += 3
	assert_eq(fired, 4, "AUTO keeps firing while held (cadence permitting)")
