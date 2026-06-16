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
