extends TestCase
## Regressions for the 2026-07-04 global review movement batch: grounded truthfulness on walk-off
## falls (M1), the airborne vault gate (M2), and the widened vault landing scan (M3).


func _loop_with_pawn(pos: Vector3) -> SimLoop:
	var sl := SimLoop.new()
	var p := Pawn.new(1)
	p.pos = pos
	p.fall_peak_y = pos.y
	sl.world.pawns[1] = p
	return sl


func test_walkoff_fall_clears_grounded_and_lands_with_fall_distance() -> void:
	# M1: grounded was only ever cleared by the jump branch, so a pawn that WALKED off a roof kept
	# grounded=true all the way down — no false->true landing edge, so landed_fall never fired and
	# a 10 m walk-off dealt zero fall damage while the same drop initiated by a jump could kill.
	var sl := _loop_with_pawn(Vector3(2, 4, 2))
	sl.platforms = [{"min": Vector3(0, 0, 0), "max": Vector3(4, 4, 4)}]
	var p: Pawn = sl.world.pawns[1]
	var went_airborne := false
	var max_landed := 0.0
	for i in 60:
		sl.step({1: {"move_x": 1.0, "move_y": 0.0, "yaw": 0.0, "buttons": 0}})   # walk +x off the edge
		if not p.grounded:
			went_airborne = true
		max_landed = maxf(max_landed, p.landed_fall)
	assert_true(went_airborne, "walking off the platform edge clears grounded (was stuck true)")
	assert_almost_eq(p.pos.y, 0.0, 0.01, "reached the ground")
	assert_true(p.grounded, "grounded again after landing")
	assert_true(max_landed >= 3.5, "landing emitted the ~4 m fall distance, got %f" % max_landed)


func test_no_mid_air_jump_while_falling() -> void:
	# M1 exploit half: with grounded stuck true, BTN_JUMP mid-fall reset velocity.y to +JUMP_V0
	# (an air-jump that also cancelled fall damage). Once airborne, jump input must do nothing.
	var sl := _loop_with_pawn(Vector3(2, 6, 2))
	var p: Pawn = sl.world.pawns[1]
	p.grounded = true   # stale flag, as after a walk-off
	sl.step({1: {"buttons": 0}})            # first step: fall begins, grounded clears
	assert_false(p.grounded, "airborne after the first falling step")
	var vy_before: float = p.velocity.y
	sl.step({1: {"buttons": InputCommand.BTN_JUMP}})
	assert_true(p.velocity.y < vy_before, "jump mid-air does not reset vertical velocity")


func test_airborne_pawn_cannot_vault_full_wall() -> void:
	# M2: can_vault only saw the blocker top RELATIVE to the feet, so a falling pawn whose feet
	# passed a 2 m wall's upper band (relative top <= 1.2) vaulted clean over a non-vaultable wall.
	var cat_res := PieceCatalog.from_json_string('{"pieces":[{"id":"wl","height":"full","health":100,"material":"METAL_THICK"}]}')
	var store := StructureStore.new(cat_res["catalog"])
	store.place(1, 0, BuildGrid.cell_of(Vector3(0, 0, 2.0)), 0, 0)   # full wall, cell z [2..4)
	var sl := _loop_with_pawn(Vector3(0, 1.0, 1.6))
	sl.structures = store
	var p: Pawn = sl.world.pawns[1]
	p.grounded = false          # mid-fall beside the wall
	p.velocity.y = -2.0
	var vaulted := false
	for i in 30:
		sl.step({1: {"move_y": 1.0}})   # push into the wall the whole way down
		vaulted = vaulted or p.vaulting
	assert_false(vaulted, "no vault was ever started while airborne")
	assert_true(p.pos.z < 2.0, "never crossed the full wall, got z=%f" % p.pos.z)


func test_vault_triggers_on_angled_approach() -> void:
	# M3: the old landing scan only sampled 1.8..2.3 m from the PAWN (not the blocker face), so any
	# approach more than ~30 degrees off perpendicular could not find clear ground inside the window
	# and the vault was silently refused — the pawn stuck sliding against a plain vaultable box.
	var cat_res := PieceCatalog.from_json_string('{"pieces":[{"id":"sb","height":"half","health":100,"material":"METAL_THIN"}]}')
	var store := StructureStore.new(cat_res["catalog"])
	store.place(1, 0, BuildGrid.cell_of(Vector3(0, 0, 2.0)), 0, 0)   # half blocker, cell x [0..2) z [2..4)
	var sl := _loop_with_pawn(Vector3(0.2, 0, 1.6))
	sl.structures = store
	var p: Pawn = sl.world.pawns[1]
	var saw_vault := false
	for i in 40:
		sl.step({1: {"move_x": 0.5, "move_y": 1.0}})   # ~27 degrees off perpendicular, into the box
		saw_vault = saw_vault or p.vaulting
	assert_true(saw_vault, "the angled approach triggers a vault instead of sticking on the box")
	assert_true(p.pos.z > 4.0, "carried past the blocker cell, got z=%f" % p.pos.z)
	assert_false(p.vaulting, "vault completed")


func _low_box_store() -> StructureStore:
	# One half-height (vaultable) blocker in cell x[0..2) z[2..4).
	var cat_res := PieceCatalog.from_json_string('{"pieces":[{"id":"sb","height":"half","health":100,"material":"METAL_THIN"}]}')
	var store := StructureStore.new(cat_res["catalog"])
	store.place(1, 0, BuildGrid.cell_of(Vector3(0, 0, 2.0)), 0, 0)
	return store


func test_human_does_not_vault_low_box_without_jump() -> void:
	# B3/B4 (round-4 playtest): vaulting is manual for humans now — auto_vault=false. Walking straight
	# into a low box with NO jump must leave the pawn blocked against it, not auto-climb (BattleBit).
	var sl := _loop_with_pawn(Vector3(1.0, 0, 1.0))
	sl.structures = _low_box_store()
	var p: Pawn = sl.world.pawns[1]
	p.auto_vault = false
	var saw_vault := false
	for i in 40:
		sl.step({1: {"move_x": 0.0, "move_y": 1.0, "buttons": 0}})   # push into the box, never jump
		saw_vault = saw_vault or p.vaulting
	assert_false(saw_vault, "a human never vaults without a jump press")
	assert_true(p.pos.z < 2.0, "stays on the near side of the blocker, got z=%f" % p.pos.z)


func test_human_vaults_low_box_on_jump_and_lands_grounded() -> void:
	# The other half: press jump while blocked against the low box and the human vaults it. The jump
	# that became a vault must NOT leave residual upward velocity (no launch when the arc completes).
	var sl := _loop_with_pawn(Vector3(1.0, 0, 1.0))
	sl.structures = _low_box_store()
	var p: Pawn = sl.world.pawns[1]
	p.auto_vault = false
	var saw_vault := false
	var last_z := -1.0
	for i in 40:
		# Approach with no jump; once the box halts our advance (grounded + stalled), press jump.
		var stalled: bool = i > 0 and absf(p.pos.z - last_z) < 0.001 and p.grounded
		last_z = p.pos.z
		var btn: int = InputCommand.BTN_JUMP if stalled else 0
		sl.step({1: {"move_x": 0.0, "move_y": 1.0, "buttons": btn}})
		saw_vault = saw_vault or p.vaulting
	assert_true(saw_vault, "jump press against the box triggers a vault")
	assert_true(p.pos.z > 4.0, "carried past the blocker cell, got z=%f" % p.pos.z)
	assert_false(p.vaulting, "vault completed")
	assert_true(p.grounded, "grounded after the vault (no leftover jump impulse)")
	assert_true(p.velocity.y <= 0.01, "no residual upward velocity, got vy=%f" % p.velocity.y)
