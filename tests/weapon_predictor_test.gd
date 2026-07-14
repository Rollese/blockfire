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


# --- Reserve-ammo economy (M17) ---

func test_set_weapon_loads_full_reserve() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	assert_eq(wp.mag, int(Weapon.get_def(Weapon.AR)["mag_size"]))
	assert_eq(wp.reserve, Weapon.reserve_ammo(Weapon.AR), "fresh weapon starts with full reserve")

func test_reload_moves_rounds_from_reserve_no_discard() -> void:
	var wp := _wp()   # AR: mag 30, reserve 180
	var start_reserve := wp.reserve
	# Fire 10 rounds (spaced beyond cadence), then reload.
	var tick := 0
	for _i in range(10):
		wp.step(tick, true, false, false); tick += 4
	assert_eq(wp.mag, 20, "10 rounds fired")
	wp.begin_reload(tick)
	wp.step(tick + int(round(float(Weapon.get_def(Weapon.AR)["reload_secs"]) / SimLoop.DT)) + 1, false, false, false)
	assert_false(wp.reloading, "reload completed")
	assert_eq(wp.mag, 30, "mag topped to full")
	# No partial-mag discard: only the 10 missing rounds come out of reserve.
	assert_eq(wp.reserve, start_reserve - 10, "reserve drops by exactly the rounds loaded")

func test_reload_limited_by_remaining_reserve() -> void:
	# M2 ammo: under the FIFO model "remaining reserve" is expressed as the next spare mag's own
	# round count (e.g. a partial mag banked from an earlier reload), not a flat reserve counter.
	var wp := _wp()
	wp.spare_mags = [5]        # only one partial spare mag left
	wp.mag = 0                 # empty mag
	wp.begin_reload(0)
	wp.step(int(round(float(Weapon.get_def(Weapon.AR)["reload_secs"]) / SimLoop.DT)) + 1, false, false, false)
	assert_eq(wp.mag, 5, "only what's in the next spare mag loads")
	assert_eq(wp.reserve, 0, "reserve (sum of spares) emptied")

func test_reload_blocked_when_reserve_empty() -> void:
	# M2 ammo: the reload-start guard is has_loadable_spare(spare_mags), not the flat reserve field.
	var wp := _wp()
	wp.spare_mags = []         # no spare mags left
	wp.mag = 3
	wp.begin_reload(0)
	assert_false(wp.reloading, "cannot reload with no loadable spare mags")
	assert_eq(wp.mag, 3, "mag unchanged")

func test_reconcile_snaps_reserve_to_authority() -> void:
	var wp := _wp()
	wp.reserve = 180
	# Authority says we actually have 90 left (e.g. a mispredicted resupply / reload).
	wp.reconcile_reserve(90)
	assert_eq(wp.reserve, 90, "reserve snaps to authoritative value")


# --- Spare-mag FIFO (M2 ammo) ---

func test_predictor_tap_reload_fifo() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 8
	wp.spare_mags = [30, 30]
	wp.begin_reload(0, false)
	wp.step(wp.reload_remaining(0) + 1, false, false, false)   # advance past reload-done
	assert_eq(wp.mag, 30)
	assert_eq(wp.spare_mags, [30, 8])

func test_predictor_fast_reload_drops_current() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.mag = 8
	wp.spare_mags = [30]
	wp.begin_reload(0, true)   # fast: 0.75x + drop current
	assert_true(wp.reload_remaining(0) < int(round(float(Weapon.get_def(Weapon.AR)["reload_secs"]) / SimLoop.DT)))
	wp.step(wp.reload_remaining(0) + 1, false, false, false)
	assert_eq(wp.mag, 30)
	assert_eq(wp.spare_mags, [])   # the 8-round mag was dropped, not banked

func test_predictor_reconcile_snaps_spare_mags() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	wp.spare_mags = [1, 2]
	wp.reconcile_spare_mags([30, 30, 30])
	assert_eq(wp.spare_mags, [30, 30, 30])

func test_predictor_set_weapon_builds_full_spare_mags() -> void:
	var wp := WeaponPredictor.new()
	wp.set_weapon(Weapon.AR)
	assert_eq(wp.spare_mags.size(), Weapon.reserve_ammo(Weapon.AR) / int(Weapon.get_def(Weapon.AR)["mag_size"]))
