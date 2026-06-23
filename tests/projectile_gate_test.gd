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
