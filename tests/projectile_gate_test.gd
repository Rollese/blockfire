extends TestCase
## M5.5-P1 Task 3 gate: bullets are stepped server-side projectiles. Proves the mechanic with NO
## bots/AI — a ServerMain built WITHOUT _ready() (no ENet), pawns placed by hand, projectiles spawned
## via a test seam and stepped tick-by-tick. Deterministic per project policy (no emergent AI gating).

func _make_server() -> Node:
	var srv = preload("res://server/server_main.gd").new()
	# member initializers already ran: _sim (SimLoop), _grid (InterestGrid), _positions ({}), etc.
	# _store and _catalog are null until _ready() — build them here. Empty store => penetration skipped.
	srv._catalog = PieceCatalog.load_file("res://pieces/pieces.json")
	srv._store = StructureStore.new(srv._catalog)
	srv._conquest = ConquestState.new()   # _ready() builds this from the map; kills need register_death
	return srv

func _add_pawn(srv, id: int, pos: Vector3, team: int) -> Pawn:
	var p: Pawn = srv._sim.world.spawn(id)   # default alive=true, health=100, stance=STAND(0)
	p.pos = pos
	p.team = team
	return p

func _rebuild_grid(srv) -> void:
	srv._grid.clear()
	srv._positions.clear()
	for id in srv._sim.world.pawns:
		var p: Pawn = srv._sim.world.pawns[id]
		srv._grid.insert(id, p.pos)
		srv._positions[id] = p.pos

func test_projectile_travels_then_hits_stationary_target() -> void:
	var srv := _make_server()
	var shooter := _add_pawn(srv, 1, Vector3(0, 0, 0), 0)
	var target := _add_pawn(srv, 2, Vector3(0, 0, 40), 1)
	_rebuild_grid(srv)
	# Aim at the target BODY CENTER (feet + half body height) so the segment crosses the capsule.
	var aim: Vector3 = target.pos + Vector3(0.0, Stance.body_height(target.stance) * 0.5, 0.0)
	var dir: Vector3 = (aim - shooter.eye_position()).normalized()
	srv._spawn_projectile_for_test(1, Weapon.AR, shooter.eye_position(), dir)
	var hp0: int = target.health
	# AR muzzle 250 m/s, 40 m => ~5 ticks (30 Hz). One step must not have arrived yet.
	srv._step_projectiles()
	assert_eq(target.health, hp0, "bullet has not arrived after one tick (40m/250mps ~5 ticks)")
	for _i in 14:
		srv._step_projectiles()
	assert_true(target.health < hp0, "bullet arrived and dealt damage")
	srv.free()

func test_projectile_drops_under_muzzle_line() -> void:
	# Fire a DMR perfectly horizontal from a known muzzle height; over a long flight gravity must
	# pull it below the muzzle line. Uses the _dbg_last_min_y test seam updated each step.
	var srv := _make_server()
	var shooter := _add_pawn(srv, 1, Vector3(0, 0, 0), 0)
	_rebuild_grid(srv)
	var muzzle: Vector3 = shooter.eye_position()
	srv._spawn_projectile_for_test(1, Weapon.DMR, muzzle, Vector3(0, 0, 1))
	# DMR range 500 m at 400 m/s => well within TTL for many ticks; step long enough to see drop.
	for _i in 60:
		srv._step_projectiles()
	assert_true(srv._dbg_last_min_y < muzzle.y, "horizontal shot dropped below muzzle line under gravity")
	srv.free()

func test_heavy_takes_less_body_damage_than_light() -> void:
	# M5.5-P2: the same body hit drops a HEAVY pawn less than a LIGHT pawn.
	var srv := _make_server()
	var heavy := _add_pawn(srv, 2, Vector3(0, 0, 5), 1); heavy.armor_class = Armor.HEAVY
	var light := _add_pawn(srv, 1, Vector3(0, 0, 0), 1); light.armor_class = Armor.LIGHT
	var hp_h0 := heavy.health
	srv._apply_pawn_damage(2, heavy, 50, false, Revive.Source.BULLET, 0, Weapon.AR)
	var heavy_loss := hp_h0 - heavy.health
	var hp_l0 := light.health
	srv._apply_pawn_damage(1, light, 50, false, Revive.Source.BULLET, 0, Weapon.AR)
	var light_loss := hp_l0 - light.health
	assert_eq(light_loss, 50, "LIGHT takes full body damage")
	assert_eq(heavy_loss, int(round(50 * 0.7)), "HEAVY body damage scaled by 0.7")
	assert_true(heavy_loss < light_loss, "HEAVY takes less body damage than LIGHT")
	srv.free()

func test_heavy_helmet_saves_from_finishing_headshot() -> void:
	# A finishing headshot (~50) that would true-kill a 40-HP pawn is downgraded to body damage
	# by the HEAVY helmet (35 < 40), so the pawn survives; a LIGHT pawn dies to the same shot.
	var srv := _make_server()
	var heavy := _add_pawn(srv, 2, Vector3(0, 0, 5), 1); heavy.armor_class = Armor.HEAVY; heavy.health = 40
	srv._apply_pawn_damage(2, heavy, 50, true, Revive.Source.BULLET, 0, Weapon.AR)
	assert_true(heavy.alive and not heavy.is_downed, "HEAVY survives a finishing headshot (helmet)")
	assert_eq(heavy.health, 40 - int(round(50 * 0.7)), "downgraded to 0.7x body damage")
	var light := _add_pawn(srv, 1, Vector3(0, 0, 0), 1); light.armor_class = Armor.LIGHT; light.health = 40
	srv._apply_pawn_damage(1, light, 50, true, Revive.Source.BULLET, 0, Weapon.AR)
	assert_false(light.alive, "LIGHT is true-killed by the same finishing headshot")
	srv.free()

func test_near_miss_accrues_suppression() -> void:
	# A bullet that passes within SUPPRESS_RADIUS of an enemy (but does NOT hit) raises its
	# suppression; a clean miss far away does not.
	var srv := _make_server()
	_add_pawn(srv, 1, Vector3(2.0, 0, 0), 0)         # owner (team 0)
	var victim := _add_pawn(srv, 2, Vector3(0, 0, 40), 1)   # enemy ~2 m off the flight line
	_rebuild_grid(srv)
	assert_almost_eq(victim.suppression, 0.0)
	# Fire parallel to +z, offset 2 m in x and ~1 m up: passes beside the victim, never hits it.
	srv._spawn_projectile_for_test(1, Weapon.AR, Vector3(2.0, 1.0, 0), Vector3(0, 0, 1))
	for _i in 12:
		srv._step_projectiles()
	assert_true(victim.suppression > 0.0, "near-miss raised suppression")
	assert_true(victim.alive and not victim.is_downed, "near-miss did not damage the victim")
	srv.free()

func test_per_slot_ammo_persists_across_swap() -> void:
	var srv := _make_server()
	var c := {
		"weapon": Weapon.AR, "weapon_def": Weapon.effective_def(Weapon.AR, {}), "class": Loadout.ASSAULT,
		"ammo": int(Weapon.get_def(Weapon.AR)["mag_size"]), "reloading": false, "reload_done_tick": 0,
		"last_fire_time": -999.0, "shot_index": 0, "fire_mode": Weapon.default_mode(Weapon.AR),
		"active_slot": 0, "swap_locked_until": 0,
	}
	srv._clients[1] = c
	srv._build_weapon_slots(c)
	c["ammo"] = 7                                   # deplete primary
	srv._sim.tick = 100
	srv._swap_weapon(1, 1)                           # -> secondary
	assert_eq(int(c["active_slot"]), 1)
	assert_eq(int(c["weapon"]), Weapon.PISTOL)
	assert_eq(int(c["ammo"]), int(Weapon.get_def(Weapon.PISTOL)["mag_size"]), "secondary starts full")
	c["ammo"] = 3                                   # deplete secondary
	srv._sim.tick = 200                              # past lockout
	srv._swap_weapon(1, 0)                           # -> back to primary
	assert_eq(int(c["weapon"]), Weapon.AR)
	assert_eq(int(c["ammo"]), 7, "primary ammo preserved across swaps (not refilled)")
	srv.free()

func test_swap_lockout_blocks_immediate_reswap() -> void:
	var srv := _make_server()
	var c := {
		"weapon": Weapon.AR, "weapon_def": Weapon.effective_def(Weapon.AR, {}), "class": Loadout.ASSAULT,
		"ammo": 30, "reloading": false, "reload_done_tick": 0, "last_fire_time": -999.0,
		"shot_index": 0, "fire_mode": Weapon.default_mode(Weapon.AR),
		"active_slot": 0, "swap_locked_until": 0,
	}
	srv._clients[1] = c
	srv._build_weapon_slots(c)
	srv._sim.tick = 50
	srv._swap_weapon(1, 1)
	assert_eq(int(c["active_slot"]), 1)
	srv._swap_weapon(1, 0)                           # same tick -> blocked by lockout
	assert_eq(int(c["active_slot"]), 1, "re-swap blocked during equip lockout")
	srv.free()

func test_respawn_resets_both_slots_to_full_on_primary() -> void:
	var srv := _make_server()
	var c := {
		"weapon": Weapon.AR, "weapon_def": Weapon.effective_def(Weapon.AR, {}), "class": Loadout.ASSAULT,
		"ammo": int(Weapon.get_def(Weapon.AR)["mag_size"]), "reloading": false, "reload_done_tick": 0,
		"last_fire_time": -999.0, "shot_index": 0, "fire_mode": Weapon.default_mode(Weapon.AR),
		"active_slot": 0, "swap_locked_until": 0,
	}
	srv._clients[1] = c
	srv._build_weapon_slots(c)
	srv._sim.tick = 100
	srv._swap_weapon(1, 1)            # to secondary
	c["ammo"] = 2                     # deplete secondary (active)
	c["slots"][0]["ammo"] = 5         # primary slot left depleted
	srv._reset_weapon_loadout(c)
	assert_eq(int(c["active_slot"]), 0)
	assert_eq(int(c["weapon"]), Weapon.AR)
	assert_eq(int(c["ammo"]), int(Weapon.get_def(Weapon.AR)["mag_size"]), "primary full after respawn")
	assert_eq(int(c["slots"][1]["ammo"]), int(Weapon.get_def(Weapon.PISTOL)["mag_size"]), "secondary full after respawn")
	assert_eq(int(c["swap_locked_until"]), 0)
	srv.free()

func test_downed_enemy_takes_no_projectile_damage_but_emits_blood() -> void:
	# BattleBit no-finishing: a bullet through a DOWNED enemy deals no damage and never blocks, but
	# the server still emits a cosmetic flesh impact. This exercises that emit path (empty _clients =>
	# no-op send) and protects the invariant that a downed pawn isn't finished by gunfire.
	var srv := _make_server()
	var shooter := _add_pawn(srv, 1, Vector3(0, 0, 0), 0)
	var target := _add_pawn(srv, 2, Vector3(0, 0, 40), 1)
	target.is_downed = true            # alive but downed (immune to finishing)
	_rebuild_grid(srv)
	var aim: Vector3 = target.pos + Vector3(0.0, Stance.body_height(target.stance) * 0.5, 0.0)
	var dir: Vector3 = (aim - shooter.eye_position()).normalized()
	srv._spawn_projectile_for_test(1, Weapon.AR, shooter.eye_position(), dir)
	var hp0: int = target.health
	for _i in 20:
		srv._step_projectiles()       # must not crash on the impact emit (no clients)
	assert_true(target.alive, "downed enemy is not finished by a bullet")
	assert_true(target.is_downed, "downed enemy stays downed")
	assert_eq(target.health, hp0, "downed enemy takes no projectile damage")
	srv.free()
