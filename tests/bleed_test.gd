extends TestCase
## M16 standing-bleed pure rules: threshold+source trigger gating and drain cadence.

func test_should_start_below_threshold_from_bullet() -> void:
	# A bullet that leaves the pawn below BLEED_THRESHOLD (60) but alive starts a bleed.
	assert_true(Bleed.should_start(59, Revive.Source.BULLET))
	assert_true(Bleed.should_start(1, Revive.Source.BULLET))

func test_should_start_below_threshold_from_blast() -> void:
	assert_true(Bleed.should_start(30, Revive.Source.BLAST))

func test_no_bleed_when_healthy_after_hit() -> void:
	# At or above the threshold: a graze that leaves you healthy never bleeds.
	assert_false(Bleed.should_start(60, Revive.Source.BULLET))
	assert_false(Bleed.should_start(100, Revive.Source.BULLET))

func test_no_bleed_when_dead() -> void:
	# post_hit_hp <= 0 is a kill, not a bleed (handled by the death branch).
	assert_false(Bleed.should_start(0, Revive.Source.BULLET))
	assert_false(Bleed.should_start(-5, Revive.Source.BLAST))

func test_fall_never_bleeds() -> void:
	# Fall damage never starts a bleed even below threshold (spec decision).
	assert_false(Bleed.should_start(20, Revive.Source.FALL))

func test_drain_cadence() -> void:
	# 1 HP is lost on ticks that are multiples of BLEED_RATE_TICKS (6), else nothing.
	assert_true(Bleed.drain_this_tick(0))
	assert_true(Bleed.drain_this_tick(Bleed.BLEED_RATE_TICKS))
	assert_true(Bleed.drain_this_tick(Bleed.BLEED_RATE_TICKS * 3))
	assert_false(Bleed.drain_this_tick(1))
	assert_false(Bleed.drain_this_tick(Bleed.BLEED_RATE_TICKS - 1))

func test_threshold_value() -> void:
	assert_eq(Bleed.BLEED_THRESHOLD, 60)
