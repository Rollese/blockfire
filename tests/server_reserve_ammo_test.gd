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
	var expected := int(round(float(Weapon.reserve_ammo(wid)) * 1.25))
	assert_eq(int(c["reserve"]), expected, "Support reserve = base × 1.25")
	assert_eq(int(c["slots"][0]["reserve"]), expected, "primary slot reflects the boost")

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
	var scaled := int(round(float(Weapon.reserve_ammo(wid)) * 1.25))
	assert_eq(srv._spawn_reserve(wid, Loadout.SUPPORT), scaled, "resupply cap uses the scaled max")
	assert_true(scaled > Weapon.reserve_ammo(wid), "scaled max exceeds base")
