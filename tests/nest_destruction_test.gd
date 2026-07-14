extends TestCase
## Server wiring for the two nest-destruction vectors + the persist-past-death invariant
## (closes the emplacement_server.gd:156 deferral). Uses the real ServerMain fixture so the sledge
## (_resolve_melee) and bullet-chip (ServerFire.step_projectiles) code paths are exercised, not mirrored.

const F := preload("res://tests/server_fixture.gd")

func _place_nest(srv, index: int, pos: Vector3, team := 1, facing := 0.0, owner := 999) -> Emplacement:
	var e := Emplacement.make(Emplacement.id_for(index), Gadget.KIND_LMG_NEST, team, pos, facing,
		{"hp": 500, "belt": 150})
	e.owner_id = owner
	srv._emplacements.nests[e.id] = e
	return e

# ---- sledgehammer -----------------------------------------------------------

func test_sledge_tears_down_a_nest_in_reach() -> void:
	var srv = autofree(F.make_server())
	var atk: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	atk.yaw = 0.0                                   # facing +Z
	F.add_client(srv, 1, 0, true)["class"] = Loadout.ENGINEER
	var e := _place_nest(srv, 5, Vector3(0, 0, 1.5), 1)   # enemy nest 1.5 m in front
	srv._resolve_melee(1, 0)
	assert_eq(e.hp, 400, "one sledge swing tears SLEDGE_NEST_DAMAGE (100) off the nest")
	assert_true(e.alive)
	assert_eq(srv._stats.sledge_hits, 1, "telemetry: the swing counted as a sledge hit")

func test_sledge_is_team_agnostic() -> void:
	var srv = autofree(F.make_server())
	var atk: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	atk.yaw = 0.0
	F.add_client(srv, 1, 0, true)["class"] = Loadout.ENGINEER
	var e := _place_nest(srv, 5, Vector3(0, 0, 1.5), 0)   # FRIENDLY nest (same team 0)
	srv._resolve_melee(1, 0)
	assert_eq(e.hp, 400, "the sledge tears down ANY nest, friendly included")

func test_quick_knife_does_not_damage_nests() -> void:
	# "Universal damage coverage" applies to the SLEDGE only — the knife stays pawn-only.
	var srv = autofree(F.make_server())
	var atk: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	atk.yaw = 0.0
	F.add_client(srv, 1, 0, true)   # default class = ASSAULT (quick-knife)
	var e := _place_nest(srv, 5, Vector3(0, 0, 1.5), 1)
	srv._resolve_melee(1, 0)
	assert_eq(e.hp, 500, "the quick-knife leaves nests untouched (sledge-only)")

func test_sledge_kills_a_low_nest_and_ejects() -> void:
	var srv = autofree(F.make_server())
	var atk: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	atk.yaw = 0.0
	F.add_client(srv, 1, 0, true)["class"] = Loadout.ENGINEER
	var e := _place_nest(srv, 5, Vector3(0, 0, 1.5), 1)
	e.hp = 60                                       # below one swing
	srv._resolve_melee(1, 0)
	assert_false(e.alive, "a swing past 0 HP destroys the nest")
	assert_eq(srv._stats.nests_destroyed, 1)

# ---- small-arms bullet-chip -------------------------------------------------

func test_bullet_chips_an_enemy_nest() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1, 0, Vector3.ZERO)
	F.add_client(srv, 1, 0, true)
	var e := _place_nest(srv, 5, Vector3(0, 0, 10), 1)   # enemy nest 10 m downrange
	srv._fire.spawn_projectile_for_test(1, Weapon.AR, Vector3(0, 1, 0), Vector3(0, 0, 1))
	srv._fire.step_projectiles()                        # ~25 m segment crosses the parapet
	assert_eq(e.hp, 500 - srv.BULLET_NEST_CHIP, "a round passing through the parapet chips it")

func test_bullet_does_not_chip_a_friendly_nest() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1, 0, Vector3.ZERO)
	F.add_client(srv, 1, 0, true)
	var e := _place_nest(srv, 5, Vector3(0, 0, 10), 0)   # SAME team as the shooter
	srv._fire.spawn_projectile_for_test(1, Weapon.AR, Vector3(0, 1, 0), Vector3(0, 0, 1))
	srv._fire.step_projectiles()
	assert_eq(e.hp, 500, "friendly fire off: own-team nests are not chipped")

func test_bullet_wide_of_the_nest_does_not_chip() -> void:
	var srv = autofree(F.make_server())
	F.add_pawn(srv, 1, 0, Vector3.ZERO)
	F.add_client(srv, 1, 0, true)
	var e := _place_nest(srv, 5, Vector3(20, 0, 10), 1)   # off to the side of the +Z shot
	srv._fire.spawn_projectile_for_test(1, Weapon.AR, Vector3(0, 1, 0), Vector3(0, 0, 1))
	srv._fire.step_projectiles()
	assert_eq(e.hp, 500, "a round that misses the parapet volume does no chip")

# ---- persist-past-death invariant -------------------------------------------

func test_nest_survives_its_owners_death() -> void:
	# Owner's rule: a deployed nest stays through death (like the grapple rope); it only leaves on
	# destruction / redeploy / disconnect. _kill_pawn must not remove it.
	var srv = autofree(F.make_server())
	var owner: Pawn = F.add_pawn(srv, 1, 0, Vector3.ZERO)
	F.add_client(srv, 1, 0, true)
	var e := _place_nest(srv, 5, Vector3(0, 0, 5), 0, 0.0, 1)   # owned by pawn 1
	srv._kill_pawn(1, owner, 2, Weapon.AR, false, Revive.Source.BULLET)
	assert_false(owner.alive, "owner is dead")
	assert_true(srv._emplacements.nests.has(e.id), "the nest persists past its owner's death")
	assert_true((srv._emplacements.nests[e.id] as Emplacement).alive, "and stays alive/usable")
