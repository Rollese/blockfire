extends TestCase
## M3 playtest fix: collapse rubble (`brubble`) must actually COLLIDE. Owner report 2026-07-13:
## "both bots and I run straight THROUGH the rubble blocks in every stance ... I could lie down and
## crouch inside them." Rubble is BattleBit low cover: it blocks the feet in every stance (you can't
## walk through it or hide prone inside it) yet stays vaultable/shoot-over-able (not a full wall).
## Exercises the REAL pieces.json so brubble's authoritative flags are what's under test.

func _store() -> StructureStore:
	return StructureStore.new(PieceCatalog.load_file("res://pieces/pieces.json"))

func _rubble() -> int:
	return PieceCatalog.load_file("res://pieces/pieces.json").index_of("brubble")

# Cell (0,0,0): world x[0,2.4] z[0,2.4], center (1.2,·,1.2); half -> top 1.2 m.

func test_rubble_blocks_a_pawn_walking_into_it() -> void:
	var s := _store()
	s.place(1, _rubble(), Vector3i(0, 0, 0), 0, 0, 0)
	# Walk from outside (z=-2) straight into the rubble cell centre.
	var from := Vector3(1.2, 0.0, -2.0)
	var to := Vector3(1.2, 0.0, 1.2)
	var got := s.resolve_movement(from, to)
	assert_true(got.distance_to(to) > 0.5, "rubble stops a pawn walking into its cell (not walk-through)")

func test_rubble_cell_is_not_standable_in_any_stance() -> void:
	# resolve_movement / stands_clear is stance-independent, so a blocked feet-cell blocks STAND,
	# CROUCH and PRONE alike — nobody can occupy or lie hidden inside the rubble.
	var s := _store()
	s.place(1, _rubble(), Vector3i(0, 0, 0), 0, 0, 0)
	assert_false(s.stands_clear(Vector3(1.2, 0.0, 1.2)), "feet cannot rest inside the rubble cell (no hiding prone/crouched inside)")

func test_rubble_is_low_cover_not_a_full_wall() -> void:
	var s := _store()
	s.place(1, _rubble(), Vector3i(0, 0, 0), 0, 0, 0)
	assert_false(s.is_tall_blocker(Vector3(1.2, 0.0, 1.2)), "rubble is LOW cover — vaultable, not a full-height wall")
	assert_true(s.ground_blocker_top(Vector3(1.2, 0.0, 1.2)) <= 1.2 + 0.001, "rubble top is within vault height (BattleBit low cover)")

func test_rubble_can_still_be_shot_over() -> void:
	var s := _store()
	s.place(1, _rubble(), Vector3i(0, 0, 0), 0, 0, 0)
	assert_true(s.march(Vector3(1.2, 0.5, -3), Vector3(0, 0, 1), 50.0)["hit"], "a knee-high shot is stopped (cover)")
	assert_false(s.march(Vector3(1.2, 1.5, -3), Vector3(0, 0, 1), 50.0)["hit"], "you can still shoot OVER ~1.2 m rubble")
