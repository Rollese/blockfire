extends TestCase

const Fixture := preload("res://tests/server_fixture.gd")

func _armed_client(srv, id: int) -> Dictionary:
	var c: Dictionary = Fixture.add_client(srv, id, 0)
	c["weapon"] = Weapon.AR
	c["ammo"] = 17
	c["spare_mags"] = [30, 30]
	return c

func test_drop_then_pickup_restores_mag() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 5, 0)
	var c := _armed_client(srv, 5)
	var n_before: int = c["spare_mags"].size()
	srv._drop_mag(5, c)
	var lst: Array = srv._dropped_mags.for_owner(5)
	assert_eq(lst.size(), 1)
	assert_eq(int(lst[0]["rounds"]), 17)
	var mag_id := int(lst[0]["id"])
	# Colocate the mag at the eye (dist < 0.5 m) so the look-dot check is skipped and pickup succeeds.
	srv._dropped_mags.set_pos(mag_id, srv._sim.world.pawns.get(5).eye_position())
	srv._pickup_mag_for(5, mag_id)
	assert_eq(srv._dropped_mags.for_owner(5).size(), 0)
	assert_eq(c["spare_mags"].size(), n_before + 1)
	assert_true(c["spare_mags"].has(17))

func test_other_player_cannot_pick_up_your_mag() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 5, 0)
	Fixture.add_pawn(srv, 6, 0)
	var owner := _armed_client(srv, 5)
	var _thief := _armed_client(srv, 6)
	srv._drop_mag(5, owner)
	var mag_id := int(srv._dropped_mags.for_owner(5)[0]["id"])
	srv._dropped_mags.set_pos(mag_id, srv._sim.world.pawns.get(6).eye_position())
	srv._pickup_mag_for(6, mag_id)   # wrong owner -> rejected
	assert_eq(srv._dropped_mags.for_owner(5).size(), 1)

func test_death_sweeps_dropped_mags() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var p = Fixture.add_pawn(srv, 5, 0)
	var c := _armed_client(srv, 5)
	srv._drop_mag(5, c)
	assert_eq(srv._dropped_mags.for_owner(5).size(), 1)
	srv._kill_pawn(5, p, 0, Weapon.AR, false, 0)
	assert_eq(srv._dropped_mags.for_owner(5).size(), 0)

func test_ttl_despawns_stale_mags() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 5, 0)
	var c := _armed_client(srv, 5)
	srv._drop_mag(5, c)
	srv._dropped_mags.step(srv._sim.tick + ServerDroppedMags.TTL_TICKS + 1)
	assert_eq(srv._dropped_mags.for_owner(5).size(), 0)

func test_stats_track_mag_dropped() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 5, 0)
	var c := _armed_client(srv, 5)
	srv._drop_mag(5, c)
	assert_true(srv._stats.mags_dropped >= 1)
