extends TestCase

func _loop_with_pawn(pos: Vector3) -> SimLoop:
	var sl := SimLoop.new()
	var p := Pawn.new(1)
	p.pos = pos
	sl.world.pawns[1] = p
	return sl

func test_step_advances_pawns_from_inputs() -> void:
	var sim := SimLoop.new()
	sim.world.spawn(1)
	sim.world.spawn(2)
	var inputs := {1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0}}
	sim.step(inputs)
	assert_eq(sim.tick, 1)
	assert_almost_eq(sim.world.get_pawn(1).pos.x, Stance.speed(Stance.STAND) * SimLoop.DT, 0.0001)
	assert_almost_eq(sim.world.get_pawn(2).pos.x, 0.0, 0.0001, "no input = no move")

func test_structures_block_movement() -> void:
	var cat = PieceCatalog.from_json_string('{"pieces":[{"id":"wall","height":"full","health":350,"blocks":"both"}]}')["catalog"]
	var store := StructureStore.new(cat)
	# Wall at ground cell (1,0,0): world x in [2,4), z in [0,2).
	store.place(1, 0, Vector3i(1, 0, 0), 0, 99)
	var sim := SimLoop.new()
	sim.structures = store
	var p := sim.world.spawn(1)
	p.pos = Vector3(1.0, 0.0, 1.0)
	# Drive straight toward +x into the wall for several ticks.
	for _i in 30:
		sim.step({1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "pitch": 0.0, "buttons": 0}})
	# The pawn must NOT have entered the blocked cell.
	assert_eq(BuildGrid.cell_of(Vector3(p.pos.x, 0.0, p.pos.z)) == Vector3i(1, 0, 0), false)
	assert_true(p.pos.x < 2.0, "blocked before the wall cell, got x=%f" % p.pos.x)

func test_records_stance_change_tick() -> void:
	var sl := _loop_with_pawn(Vector3.ZERO)
	sl.step({1: {}})                                   # tick 0 -> stance STAND, no change from default
	sl.step({1: {"buttons": InputCommand.BTN_PRONE}})  # tick 1 -> STAND->PRONE
	assert_eq(sl.world.pawns[1].last_stance_change_tick, 1)

func test_engages_ladder_and_climbs() -> void:
	var sl := _loop_with_pawn(Vector3(5, 0, 5))
	sl.ladders = [{"bottom": Vector3(5, 0, 5), "top": Vector3(5, 4, 5), "radius": 0.6}]
	# move_y forward (toward +z is up-intent on the ladder); push up several ticks
	for i in 20:
		sl.step({1: {"move_y": 1.0}})
	var p: Pawn = sl.world.pawns[1]
	assert_true(p.pos.y > 1.0, "pawn climbed the ladder")

func test_platform_holds_pawn_above_ground() -> void:
	var sl := _loop_with_pawn(Vector3(5, 4, 5))
	sl.platforms = [{"min": Vector3(0, 0, 0), "max": Vector3(10, 4, 10)}]
	for i in 10:
		sl.step({1: {}})   # gravity would pull to 0 without platform support
	assert_almost_eq(sl.world.pawns[1].pos.y, 4.0)

func test_vaults_low_structure_blocker() -> void:
	var cat_res := PieceCatalog.from_json_string('{"pieces":[{"id":"sb","height":"half","health":100,"material":"METAL_THIN"}]}')
	var store := StructureStore.new(cat_res["catalog"])
	# Place a half piece one cell ahead (+z) of the pawn.
	# Cell (0,0,1) covers z in [2,4). Pawn starts at z=1.6 so it reaches the blocked
	# cell boundary in 2 ticks (at 0.2 m/tick STAND speed), leaving 10+ ticks to complete
	# the vault arc (VAULT_TICKS=8).
	var ahead := Vector3(0, 0, 2.0)
	store.place(1, 0, BuildGrid.cell_of(ahead), 0, 0)
	var sl := _loop_with_pawn(Vector3(0, 0, 1.6))
	sl.structures = store
	# Drive forward into the half piece while standing -> should start a vault and end past it.
	var saw_vault := false
	for i in Vault.VAULT_TICKS + 4:
		sl.step({1: {"move_y": 1.0}})
		saw_vault = saw_vault or sl.world.pawns[1].vaulting
	var p: Pawn = sl.world.pawns[1]
	assert_true(p.pos.z > 2.0, "vaulted past the half-height blocker")
	assert_false(p.vaulting, "vault completed")
	# Landing must be near the vault arc target, NOT a free walk-through past it.
	assert_true(p.pos.z >= 4.0, "reached at least the vault landing distance")
	assert_true(p.pos.z <= 5.5, "ended near the vault landing, not free-walked far past the blocker")
	assert_true(saw_vault, "a vault was actually triggered")

func test_descends_ladder_and_dismounts_at_bottom() -> void:
	var sl := _loop_with_pawn(Vector3(5, 3.5, 5))
	sl.ladders = [{"bottom": Vector3(5, 0, 5), "top": Vector3(5, 4, 5), "radius": 0.6}]
	# First engage by climbing up a touch, then drive down to the bottom.
	sl.world.pawns[1].climbing = true   # already on the ladder, mid-height
	for i in 60:
		sl.step({1: {"move_y": -1.0}})   # descend
	var p: Pawn = sl.world.pawns[1]
	assert_almost_eq(p.pos.y, 0.0, 0.05, "descended to the ladder bottom and dismounted to ground")
	assert_false(p.climbing, "dismounted at the bottom")
