extends TestCase
## M19 P5: pure Riot Shield arc geometry + small-arms classifier.

func test_blocks_dead_ahead() -> void:
	assert_true(RiotShield.blocks(0.0, 0.0), "dead-ahead is blocked")

func test_blocks_at_arc_edge_and_beyond() -> void:
	var edge := deg_to_rad(RiotShield.SHIELD_ARC_DEG)
	assert_true(RiotShield.blocks(0.0, edge - 0.01), "just inside the arc is blocked")
	assert_false(RiotShield.blocks(0.0, edge + 0.01), "just past the arc is open")

func test_open_from_behind() -> void:
	assert_false(RiotShield.blocks(0.0, PI), "directly behind is open")

func test_symmetric_left_right() -> void:
	var a := deg_to_rad(RiotShield.SHIELD_ARC_DEG) - 0.05
	assert_true(RiotShield.blocks(0.0, a), "right side inside arc blocked")
	assert_true(RiotShield.blocks(0.0, -a), "left side inside arc blocked")

func test_wraps_across_pi() -> void:
	assert_true(RiotShield.blocks(PI - 0.02, -PI + 0.02), "wrap-around front is blocked")

func test_small_arms_classifier() -> void:
	assert_true(RiotShield.is_small_arms(Revive.Source.BULLET, false), "front bullet is small-arms")
	assert_false(RiotShield.is_small_arms(Revive.Source.BULLET, true), "back-stab bypasses")
	assert_false(RiotShield.is_small_arms(Revive.Source.BLAST, false), "explosive bypasses")
	assert_false(RiotShield.is_small_arms(Revive.Source.FALL, false), "fall bypasses")
