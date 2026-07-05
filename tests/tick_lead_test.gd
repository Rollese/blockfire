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

# ---- closed-loop jitter simulation (spec test plan #2) ------------------------------------
# Client and server tick at the same nominal 30 Hz; packets arrive after a jittered delay
# carrying the last-3-frames redundancy bundle (input_command.gd model); the server drains one
# frame per tick (reusing last_input on starvation), and the post-drain depth travels back to
# the client with snapshot latency. Two real-world stressors from the spec's diagnosis:
#  - `start_offset`: the connection-dependent send/drain phase ("varying per reconnect") — the
#    client is that many frames ahead, buffer AND transit pipe pre-filled, when draining starts.
#  - `drift_every`: client/server clock skew ("…and never corrected"). +N: the client's input
#    clock runs fast, producing one extra frame every N ticks; -N: runs slow, skipping one.
#    Unmanaged, drift ratchets the depth into an edge and clips there forever; the loop's whole
#    job is to absorb it with sub-perceptual whole-frame nudges.
# Deterministic: seeded RNG.

func _run_loop_sim(enabled: bool, seed_v: int, ticks: int, start_offset: int, drift_every: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var buf := InputBuffer.new()
	var lead := TickLead.new()
	var in_flight: Array = []      # {arrive: int, frames: Array} input bundles in transit
	var feedback: Array = []       # {arrive: int, depth: int} depth samples in transit
	var history: Array = []        # client redundancy ring (last 3 frames)
	var client_tick := 0
	var starvation := 0
	var depth_sum := 0.0
	var depth_n := 0
	var warmup := 300
	# Connection phase: the client has been sending for a while when the server's drain starts —
	# `start_offset` frames already buffered, plus the 2-tick transit pipe already full (without
	# the full pipe the offset would just drain away in the first 2 ticks instead of persisting).
	for _pre in start_offset:
		history.append({"client_tick": client_tick})
		while history.size() > 3:
			history.pop_front()
		client_tick += 1
	if start_offset > 0:
		buf.ingest(history.duplicate(true))
	for pipe in 2:
		history.append({"client_tick": client_tick})
		while history.size() > 3:
			history.pop_front()
		client_tick += 1
		in_flight.append({"arrive": pipe, "frames": history.duplicate(true)})
	for t in ticks:
		# Client: produce 0/1/2 frames this tick (tick-lead pacing), +-1 from clock drift.
		var reps := lead.frame_repeats() if enabled else 1
		if drift_every > 0 and t % drift_every == 0:
			reps += 1
		elif drift_every < 0 and t % (-drift_every) == 0:
			reps = maxi(0, reps - 1)
		for _r in reps:
			history.append({"client_tick": client_tick})
			while history.size() > 3:
				history.pop_front()
			client_tick += 1
		if reps > 0:
			# Base 2-tick transit; 25% of packets +1 tick late, 5% +3 (burst).
			var delay := 2
			if rng.randf() < 0.25: delay += 1
			if rng.randf() < 0.05: delay += 3
			in_flight.append({"arrive": t + delay, "frames": history.duplicate(true)})
		# Server: ingest every due bundle (redundancy dedup inside InputBuffer), drain one.
		var remaining: Array = []
		for p in in_flight:
			if int(p["arrive"]) <= t:
				buf.ingest(p["frames"])
			else:
				remaining.append(p)
		in_flight = remaining
		if buf.pop() == null:
			starvation += 1
		var depth := buf.size()
		if t >= warmup:
			depth_sum += depth
			depth_n += 1
		feedback.append({"arrive": t + 2, "depth": depth})   # snapshot travel back ~2 ticks
		var fb_remaining: Array = []
		for s in feedback:
			if int(s["arrive"]) <= t:
				lead.on_depth(int(s["depth"]))
			else:
				fb_remaining.append(s)
		feedback = fb_remaining
	return {"starvation": starvation, "coalesced": buf.coalesced,
		"mean_depth": depth_sum / maxf(1.0, float(depth_n))}

func test_loop_converges_depth_to_target_from_any_phase_offset() -> void:
	# Whatever depth the connection's initial phase pinned the buffer at, the loop pulls it to
	# TARGET — the lead stops being connection-dependent (the per-reconnect variability).
	for offset in [0, 2, 4]:
		for seed_v in [11, 47, 2026]:
			var r := _run_loop_sim(true, seed_v, 3000, offset, 0)
			assert_true(absf(float(r["mean_depth"]) - float(TickLead.TARGET)) <= 1.0,
				"offset %d seed %d: mean depth %.2f within TARGET+-1" % [offset, seed_v, float(r["mean_depth"])])

func test_loop_absorbs_clock_drift_baseline_cannot() -> void:
	# Clock skew of one frame per 150 ticks (~0.7%), both directions. Unmanaged, every drifted
	# frame eventually clips a buffer edge (coalesce when fast, starve when slow) — ~20 edge
	# events per 3000-tick run, each one a reconcile-length change (the ~1 Hz snap). The loop
	# counteracts drift with paced holds/catch-ups, keeping edge events to isolated jitter bursts.
	# Measured (seeds 11/47/2026): fast 57 -> 28 (2.0x — the coalesce edge is only TARGET+2 away,
	# so transient depth-3 windows stay burst-vulnerable), slow 60 -> 13 (4.6x). Per-direction we
	# assert a >=30% cut (headroom vs engine-RNG changes); the aggregate test asserts full halving.
	for drift in [150, -150]:
		var base_events := 0
		var loop_events := 0
		for seed_v in [11, 47, 2026]:
			var b := _run_loop_sim(false, seed_v, 3000, 2, drift)
			var l := _run_loop_sim(true, seed_v, 3000, 2, drift)
			base_events += int(b["starvation"]) + int(b["coalesced"])
			loop_events += int(l["starvation"]) + int(l["coalesced"])
		assert_true(base_events >= 30,
			"drift %d must stress the unmanaged baseline (got %d edge events)" % [drift, base_events])
		assert_true(loop_events * 10 < base_events * 7,
			"drift %d: loop cuts edge events by >=30%% (loop %d vs baseline %d)" % [drift, loop_events, base_events])

func test_loop_cuts_edge_events_across_phases_and_drift() -> void:
	# Overall claim from the spec's Goal: starvation + coalescing become RARE — summed across
	# connection phases, drift directions and seeds, the loop at least halves buffer-edge events.
	var base_events := 0
	var loop_events := 0
	for offset in [0, 4]:
		for drift in [-150, 0, 150]:
			for seed_v in [11, 47, 2026]:
				var b := _run_loop_sim(false, seed_v, 3000, offset, drift)
				var l := _run_loop_sim(true, seed_v, 3000, offset, drift)
				base_events += int(b["starvation"]) + int(b["coalesced"])
				loop_events += int(l["starvation"]) + int(l["coalesced"])
	assert_true(base_events > 0, "baseline must actually stress the buffer (else the test proves nothing)")
	assert_true(loop_events * 2 < base_events,
		"tick-lead loop halves buffer-edge events (loop %d vs baseline %d)" % [loop_events, base_events])
