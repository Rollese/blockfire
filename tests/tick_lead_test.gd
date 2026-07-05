extends TestCase
## Tick-lead control law (docs/specs/netcode-tick-lead.md): the client nudges its input
## production clock by whole frames — at most one adjust per physics frame, a few per
## second (GAIN-limited) — so the server-side InputBuffer depth converges to TARGET.

func test_at_target_never_adjusts() -> void:
	var l := TickLead.new()
	for _i in 300:
		l.on_depth(TickLead.TARGET)
		assert_eq(l.frame_repeats(), 1, "constant-at-target input must be stable (no oscillation)")

func test_full_buffer_emits_holds_at_gain_cadence() -> void:
	# depth pinned at TARGET+2 -> error clamps to +1 -> phase grows by GAIN per sample.
	# One hold (repeats 0) every ~1/GAIN samples; never two adjusts in one frame.
	var l := TickLead.new()
	var holds := 0
	var frames := 300
	for _i in frames:
		l.on_depth(TickLead.TARGET + 2)
		var r := l.frame_repeats()
		assert_true(r == 0 or r == 1, "over-full buffer only ever holds or runs normally")
		if r == 0: holds += 1
	var expected := int(floor(frames * TickLead.GAIN))
	assert_true(absi(holds - expected) <= 1, "hold cadence ~= GAIN per sample (got %d, want ~%d)" % [holds, expected])

func test_starved_buffer_emits_catch_ups() -> void:
	var l := TickLead.new()
	var extras := 0
	var frames := 300
	for _i in frames:
		l.on_depth(0)   # starved: error clamps to -1
		var r := l.frame_repeats()
		assert_true(r == 1 or r == 2, "starved buffer only ever runs normally or catches up")
		if r == 2: extras += 1
	var expected := int(floor(frames * TickLead.GAIN))
	assert_true(absi(extras - expected) <= 1, "catch-up cadence ~= GAIN per sample (got %d, want ~%d)" % [extras, expected])

func test_error_is_clamped_per_sample() -> void:
	# A single wild sample (huge depth) must move phase by at most GAIN — no burst corrections.
	var l := TickLead.new()
	l.on_depth(255)
	assert_eq(l.frame_repeats(), 1, "one outlier sample never triggers an immediate adjust")

func test_reset_clears_phase() -> void:
	var l := TickLead.new()
	for _i in 25:
		l.on_depth(TickLead.TARGET + 2)   # accumulate toward a hold
	l.reset()
	for _i in 10:
		l.on_depth(TickLead.TARGET)
		assert_eq(l.frame_repeats(), 1, "reset drops accumulated phase")

func test_counters_track_adjusts() -> void:
	var l := TickLead.new()
	for _i in 100:
		l.on_depth(TickLead.TARGET + 2)
		l.frame_repeats()
	assert_true(l.holds >= 4, "hold telemetry counts")
	assert_eq(l.extras, 0)
	assert_eq(l.last_depth, TickLead.TARGET + 2)
