extends TestCase
## Reserve-ammo economy (M17): the authoritative resupply paths refill the finite spare pool, not
## just the loaded mag. Reload-deduct math itself is covered by weapon_test (Weapon.reload_fill,
## shared by server + predictor) and weapon_predictor_test; this exercises the server resupply wiring
## through the real ServerMain via the shared fixture.

const Fixture := preload("res://tests/server_fixture.gd")

func _client_with_ammo(srv, id: int, mag: int, reserve: int) -> Dictionary:
	var c: Dictionary = Fixture.add_client(srv, id, 0)
	c["weapon"] = Weapon.AR
	c["ammo"] = mag
	c["reserve"] = reserve
	return c

func test_give_ammo_adds_one_mag_per_period_not_instant() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 7, Loadout.ASSAULT)   # spawns with full ammo + full spare mags
	c["ammo"] = 0
	c["spare_mags"] = []
	c["ammo_resupply_next_tick"] = 0
	var ms := int(Weapon.get_def(int(c["weapon"]))["mag_size"])
	srv._support.give_ammo(7, 1)   # period 1 -> runs on tick 0
	var total: int = int(c["ammo"]) + srv._sum_mags(c["spare_mags"])
	assert_true(total > 0, "some ammo dispensed")
	assert_true(total <= ms, "at most one mag's worth per period (not instant-to-full)")

func test_give_ammo_noop_when_everything_full() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 8, Loadout.ASSAULT)   # full ammo + full spares from spawn
	var p: Pawn = srv._sim.world.get_pawn(8)
	p.bandage_count = 99   # bandages already full so nothing dispenses
	c["ammo_resupply_next_tick"] = 0
	var before: Array = c["spare_mags"].duplicate()
	srv._support.give_ammo(8, 1)
	assert_eq(c["spare_mags"], before, "no over-refill when mag + spares already full")

func test_give_ammo_throttled_to_one_per_period() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 9, Loadout.ASSAULT)
	c["ammo"] = 0
	c["spare_mags"] = []
	c["ammo_resupply_next_tick"] = 0
	var ms := int(Weapon.get_def(int(c["weapon"]))["mag_size"])
	# Two calls on the SAME tick (period 1): the throttle allows only the first to dispense ammo.
	srv._support.give_ammo(9, 1)
	var after_first: int = int(c["ammo"]) + srv._sum_mags(c["spare_mags"])
	srv._support.give_ammo(9, 1)
	var after_second: int = int(c["ammo"]) + srv._sum_mags(c["spare_mags"])
	assert_eq(after_second, after_first, "second give on the same tick is throttled (<= one mag/period)")
	assert_true(after_first <= ms)

## M19 P2a — Support carries extra spare ammo (class_traits reserve_mult=1.25) both at spawn and when
## an ammo bag / Support tool tops the reserve pool back up (so a resupply never strips the bonus).
func _spawn_class(srv, id: int, cls: int) -> Dictionary:
	var c := Fixture.add_client(srv, id, 0, false)
	c["loadout"] = Loadout.default_loadout(cls)
	c["class"] = cls
	var p := Fixture.add_pawn(srv, id, 0, Vector3.ZERO)
	srv._apply_loadout_to_client(c, p)
	return c

func test_support_spawns_with_boosted_reserve() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 1, Loadout.SUPPORT)
	var wid := int(c["weapon"])
	# M2 ammo: reserve is now the sum of whole discrete spare mags (Support ×1.25 rounded to a whole
	# mag count), so it equals sum(spawn_mags), not the raw rounded round-total.
	var full := Weapon.spawn_mags(wid, 1.25)
	var expected := 0
	for m in full:
		expected += int(m)
	assert_eq(int(c["reserve"]), expected, "Support reserve = sum of discrete boosted spare mags")
	assert_eq(int(c["slots"][0]["reserve"]), expected, "primary slot reflects the boost")
	assert_true(expected > Weapon.reserve_ammo(wid), "Support boost is a real whole-mag increase over base")

func test_assault_reserve_unchanged() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 1, Loadout.ASSAULT)
	assert_eq(int(c["reserve"]), int(Weapon.reserve_ammo(int(c["weapon"]))), "Assault ×1.0")

func test_support_resupply_keeps_boost() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 1, Loadout.SUPPORT)
	var wid := int(c["weapon"])
	# M2 ammo: the resupply cap is the discrete boosted spare-mag total (sum of whole mags).
	var full := Weapon.spawn_mags(wid, 1.25)
	var scaled := 0
	for m in full:
		scaled += int(m)
	assert_eq(srv._spawn_reserve(wid, Loadout.SUPPORT), scaled, "resupply cap uses the discrete scaled max")
	assert_true(scaled > Weapon.reserve_ammo(wid), "scaled max exceeds base")

func test_tap_reload_is_fifo_and_banks_partial() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 7, 0)
	var c := _client_with_ammo(srv, 7, 8, 60)
	c["spare_mags"] = [30, 30]
	c["reloading"] = true
	c["reload_fast"] = false
	c["reload_done_tick"] = srv._sim.tick
	srv._finish_reload(c)
	assert_eq(int(c["ammo"]), 30)
	assert_eq(c["spare_mags"], [30, 8])

func test_fast_reload_loads_next_without_banking() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 9, 0)
	var c := _client_with_ammo(srv, 9, 8, 30)
	c["spare_mags"] = [30]
	c["reloading"] = true
	c["reload_fast"] = true   # current mag already dropped by _drop_mag at start
	c["reload_done_tick"] = srv._sim.tick
	srv._finish_reload(c)
	assert_eq(int(c["ammo"]), 30)
	assert_eq(c["spare_mags"], [])   # the 8-round mag was NOT banked (it was dropped)

func test_spawn_builds_full_spare_mags() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var c := _spawn_class(srv, 1, Loadout.ASSAULT)
	var wid := int(c["weapon"])
	var ms := int(Weapon.get_def(wid)["mag_size"])
	assert_eq(c["spare_mags"].size(), Weapon.reserve_ammo(wid) / ms)
	for m in c["spare_mags"]:
		assert_eq(int(m), ms)

func test_redistribute_consolidates_one_mag_per_period() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 3, 0)
	var c := _client_with_ammo(srv, 3, 30, 0)
	c["spare_mags"] = [20, 5, 30]
	c["redist_next_tick"] = 0
	# First held call arms the 5 s window (no consolidation yet).
	srv._step_redistribute(c, true, srv._sim.tick)
	assert_eq(c["spare_mags"], [20, 5, 30])
	# After the period elapses, one consolidation happens: 5 pours into 20 -> [25,30], empty dropped.
	srv._step_redistribute(c, true, srv._sim.tick + srv.REDISTRIBUTE_PERIOD_TICKS)
	assert_eq(c["spare_mags"], [25, 30])

func test_redistribute_resets_cadence_on_release() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 3, 0)
	var c := _client_with_ammo(srv, 3, 30, 0)
	c["redist_next_tick"] = srv._sim.tick + 999
	srv._step_redistribute(c, false, srv._sim.tick)   # released
	assert_eq(int(c["redist_next_tick"]), 0)

func test_redistribute_increments_stat() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 3, 0)
	var c := _client_with_ammo(srv, 3, 30, 0)
	c["spare_mags"] = [20, 5]
	c["redist_next_tick"] = 0
	srv._step_redistribute(c, true, srv._sim.tick)                                   # arm the window
	srv._step_redistribute(c, true, srv._sim.tick + srv.REDISTRIBUTE_PERIOD_TICKS)   # consolidate 5 into 20
	assert_true(srv._stats.redistributes >= 1)
