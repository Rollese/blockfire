extends TestCase

func _mounted(h: EmplacementHarness) -> void:
	h.add_support(Vector3(0, 0, 0))
	h.deploy(Vector3(0, 0, 5), Vector3(0, 0, 1))   # facing +Z (yaw 0)
	h.move_pawn_to(h.first_nest().seat_world())
	h.mount(h.first_nest_id())

func test_fire_hits_enemy_in_arc_and_consumes_belt() -> void:
	var h := EmplacementHarness.new()
	_mounted(h)
	var enemy := h.add_enemy(Vector3(0, 0, 40))   # dead ahead, in arc + range
	var belt0 := h.first_nest().ammo
	h.set_fire(true)
	for i in range(20): h.tick()
	assert_true(h.first_nest().ammo < belt0, "belt consumed while firing")
	assert_true(h.enemy_hp(enemy) < 100, "enemy in-arc took damage")

func test_fire_misses_out_of_arc() -> void:
	var h := EmplacementHarness.new()
	_mounted(h)
	var enemy := h.add_enemy(Vector3(40, 0, 5))   # 90 deg to the side -> outside the 45-deg arc
	h.set_pawn_yaw(deg_to_rad(90)); h.set_fire(true)
	for i in range(20): h.tick()
	assert_eq(h.enemy_hp(enemy), 100, "out-of-arc enemy unharmed (turret clamps)")

func test_overheat_locks_fire() -> void:
	var h := EmplacementHarness.new()
	_mounted(h)
	h.set_fire(true)
	for i in range(120): h.tick()   # holding > overheat_ticks (90)
	assert_true(Emplacement.overheated(h.first_nest().overheated_until, h.tick_now()), "sustained fire overheats")
	# while locked, holding fire must NOT put rounds downrange
	var enemy := h.add_enemy(Vector3(0, 0, 40))
	var belt_at_lock := h.first_nest().ammo
	for i in range(10): h.tick()
	assert_eq(h.enemy_hp(enemy), 100, "overheated nest doesn't fire")
	assert_eq(h.first_nest().ammo, belt_at_lock, "overheated nest consumes no belt")

func test_no_fire_when_not_holding() -> void:
	var h := EmplacementHarness.new()
	_mounted(h)
	var enemy := h.add_enemy(Vector3(0, 0, 40))
	var belt0 := h.first_nest().ammo
	h.set_fire(false)
	for i in range(20): h.tick()
	assert_eq(h.enemy_hp(enemy), 100, "no fire when trigger not held")
	assert_eq(h.first_nest().ammo, belt0, "belt untouched when not firing")

func test_empty_belt_reloads_then_refills() -> void:
	var h := EmplacementHarness.new()
	_mounted(h)
	h.set_fire(true)
	h.first_nest().ammo = 0
	h.tick()   # step_fire sees empty belt -> starts reload
	assert_true(h.first_nest().reloading_until > 0, "empty belt starts a reload")
	for i in range(140): h.tick()   # reload_ticks = 135
	assert_true(h.first_nest().ammo > 0, "belt refilled after reload")
	assert_eq(h.first_nest().reloading_until, 0)
