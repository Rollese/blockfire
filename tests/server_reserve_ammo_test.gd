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

func test_support_give_ammo_refills_reserve() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	Fixture.add_pawn(srv, 7, 0)
	var c := _client_with_ammo(srv, 7, 10, 40)   # depleted mag + partial reserve
	srv._support.give_ammo(7, 1)   # period 1 → dispenses on tick 0
	assert_eq(int(c["ammo"]), int(Weapon.get_def(Weapon.AR)["mag_size"]), "mag topped to full")
	assert_eq(int(c["reserve"]), Weapon.reserve_ammo(Weapon.AR), "reserve refilled to weapon max")

func test_support_give_ammo_noop_when_everything_full() -> void:
	var srv = Fixture.make_server()
	autofree(srv)
	var p := Fixture.add_pawn(srv, 8, 0)
	p.bandage_count = 99   # bandages already full so the give short-circuits
	var full_mag: int = int(Weapon.get_def(Weapon.AR)["mag_size"])
	var c := _client_with_ammo(srv, 8, full_mag, Weapon.reserve_ammo(Weapon.AR))
	var before_bandages := p.bandage_count
	srv._support.give_ammo(8, 1)
	assert_eq(int(c["reserve"]), Weapon.reserve_ammo(Weapon.AR), "reserve stays at max (no over-refill)")
	assert_eq(p.bandage_count, before_bandages, "nothing dispensed when mag+reserve+bandages already full")
