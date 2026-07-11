# Tick-Lead Netcode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/specs/netcode-tick-lead.md` — a closed loop that holds the server's per-client input buffer at a stable depth of 2 so the reconcile-replay length stops wandering (the residual movement micro-snap).

**Architecture:** Server samples `input_buf.size()` right after the per-tick drain and appends it as a trailing `u8` on `SELF_STATE` (append-only, VERSION 3→4). A new `client/tick_lead.gd` control law accumulates a fractional phase from the depth error and tells `client_main` to produce 0 (hold), 1 (normal), or 2 (catch-up) input frames per physics tick. Bots (`bots/bot_driver.gd`) never touch this path.

**Tech Stack:** GDScript / Godot 4 headless; existing TestCase auto-discovery runner (`godot --headless --path . -- --test`).

**Branch:** `tick-lead-netcode` off master. Land per AGENTS.md §11 (commit → merge master → push).

---

### Task 1: TickLead control law (`client/tick_lead.gd`)

**Files:**
- Create: `client/tick_lead.gd`
- Test: `tests/tick_lead_test.gd`

- [ ] **Step 1: Write the failing unit tests**

```gdscript
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
	# One hold (repeats 0) every ceil(1/GAIN) samples; never two adjusts in one frame.
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
```

- [ ] **Step 2: Run to verify failure**

Run: `godot --headless --path . -- --test --filter=tick_lead` (needs `--import` once if fresh checkout)
Expected: FAIL — `TickLead` not defined / file fails to parse.

- [ ] **Step 3: Implement `client/tick_lead.gd`**

```gdscript
class_name TickLead
extends RefCounted
## Client input-clock tick-lead management (docs/specs/netcode-tick-lead.md). The server reports
## its per-client InputBuffer depth on each SELF_STATE; this accumulator nudges WHEN the client
## produces input frames — hold one (repeats 0) when the buffer runs too full, emit an extra
## (repeats 2) when it runs too shallow — so the buffer converges to TARGET and the reconcile
## replay length stops wandering (the ~1 Hz movement micro-snap). Standard adaptive tick-sync;
## no gameplay rule logic moves to the client (AGENTS.md §7) — this only paces intent sampling.

const TARGET := 2      # frames (~66 ms at 30 Hz): 1 above empty, well under InputBuffer.MAX_DEPTH=4
const GAIN := 0.05     # phase per depth-error unit per sample — slow, below perceptual threshold

var _phase := 0.0      # fractional pending correction; +-1.0 converts to one whole-frame adjust

# Telemetry for the [client-dbg] line / feel-gate meter.
var holds := 0         # frames held (buffer was too full)
var extras := 0        # extra frames emitted (buffer was too shallow)
var last_depth := -1   # most recent reported depth (-1: none yet)

## Feed one authoritative buffer-depth sample (SELF_STATE trailing byte). Error is clamped to
## +-1 so a single outlier sample can never swing the phase by more than GAIN.
func on_depth(depth: int) -> void:
	last_depth = depth
	_phase += clampf(float(depth - TARGET), -1.0, 1.0) * GAIN

## How many input frames to produce this physics frame: 0 = hold (let the server drain the
## surplus), 1 = normal, 2 = catch up. At most one whole-frame adjust per call.
func frame_repeats() -> int:
	if _phase >= 1.0:
		_phase -= 1.0
		holds += 1
		return 0
	if _phase <= -1.0:
		_phase += 1.0
		extras += 1
		return 2
	return 1

## Drop accumulated phase (deploy/respawn: the buffer refills from scratch).
func reset() -> void:
	_phase = 0.0
```

- [ ] **Step 4: Run to verify pass** — same command, expect all `tick_lead` tests PASS.

- [ ] **Step 5: Commit** — `feat(netcode): TickLead control law (spec docs/specs/netcode-tick-lead.md)`

---

### Task 2: Closed-loop jitter simulation test (spec test plan #2)

**Files:**
- Modify: `tests/tick_lead_test.gd` (append)

- [ ] **Step 1: Write the failing closed-loop test**

Append to `tests/tick_lead_test.gd`:

```gdscript
# ---- closed-loop jitter simulation (spec test plan #2) ------------------------------------
# Client and server tick at the same 30 Hz rate; packets arrive after a jittered delay carrying
# the last-3-frames redundancy bundle (input_command.gd model); the server drains one frame per
# tick into last_input on starvation, and the post-drain depth travels back to the client with
# snapshot latency. Deterministic: seeded RNG.

func _run_loop_sim(enabled: bool, seed_v: int, ticks: int) -> Dictionary:
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
	for t in ticks:
		# Client: produce 0/1/2 frames this tick, send one bundle if any frame was produced.
		var reps := lead.frame_repeats() if enabled else 1
		for _r in reps:
			history.append({"client_tick": client_tick, "move_x": 0.0, "move_y": 0.0,
				"yaw": 0.0, "pitch": 0.0, "buttons": 0, "view_server_tick": 0})
			while history.size() > 3:
				history.pop_front()
			client_tick += 1
		if reps > 0:
			# Base 2-tick transit; 25% of packets +1 tick late, 5% +3 (burst) — enough jitter to
			# push an unmanaged buffer across both edges over a few thousand ticks.
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

func test_loop_converges_depth_to_target() -> void:
	for seed_v in [11, 47, 2026]:
		var r := _run_loop_sim(true, seed_v, 3000)
		assert_true(absf(float(r["mean_depth"]) - float(TickLead.TARGET)) <= 1.0,
			"seed %d: mean depth %.2f within TARGET+-1" % [seed_v, float(r["mean_depth"])])

func test_loop_cuts_starvation_and_coalescing_vs_baseline() -> void:
	var base_events := 0
	var loop_events := 0
	for seed_v in [11, 47, 2026]:
		var b := _run_loop_sim(false, seed_v, 3000)
		var l := _run_loop_sim(true, seed_v, 3000)
		base_events += int(b["starvation"]) + int(b["coalesced"])
		loop_events += int(l["starvation"]) + int(l["coalesced"])
	assert_true(base_events > 0, "baseline jitter must actually stress the buffer (else the test proves nothing)")
	assert_true(loop_events * 2 < base_events,
		"tick-lead loop halves buffer-edge events (loop %d vs baseline %d)" % [loop_events, base_events])
```

- [ ] **Step 2: Run** `--filter=tick_lead` — the two new tests should FAIL only if the law misbehaves; if the baseline assertion (`base_events > 0`) fails, raise the jitter probabilities (0.25/0.05) until the baseline actually crosses buffer edges, keeping determinism (same seeds). Tune assertions honestly — never weaken the `loop_events * 2 < base_events` claim; if it fails, the loop (or sim wiring) is wrong: debug with systematic-debugging before touching thresholds.

- [ ] **Step 3: All green → Commit** — `test(netcode): closed-loop jitter sim proves tick-lead convergence + edge-event reduction`

---

### Task 3: Wire byte — SELF_STATE `input_buf_depth`, VERSION 3→4, registry

**Files:**
- Modify: `shared/net/protocol.gd` (line 19 VERSION; `encode_self_state` ~line 738; `decode_self_state` ~line 795)
- Modify: `docs/specs/wire-protocol-registry.md` (header VERSION note + msg 22 row)
- Test: `tests/protocol_test.gd` (append after `test_self_state_sprint_locked_defaults_when_absent`, ~line 381)

- [ ] **Step 1: Write the failing round-trip tests**

```gdscript
func test_self_state_carries_input_buf_depth() -> void:
	# Tick-lead netcode: the server's post-drain InputBuffer depth rides SELF_STATE so the client
	# can hold its input clock at a stable lead (docs/specs/netcode-tick-lead.md).
	var b := Protocol.encode_self_state(17, false, 0, Weapon.AR, [], false, 0.0, 0, 0, false, 0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 3)
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["input_buf_depth"]), 3, "input buffer depth round-trips")

func test_self_state_input_buf_depth_absent_is_sentinel() -> void:
	# Old/short packets must decode as -1 (absent) so the tick-lead loop stays idle rather than
	# treating "no data" as "buffer empty" and wrongly emitting catch-up frames.
	var b := Protocol.encode_self_state(17, false, 0, Weapon.AR, [], false, 0.0, 0, 0, false, 0.0, 0.0, 100.0, 0.0, true, false, 0, 0.0, false, 3)
	b.resize(b.size() - 1)   # drop the trailing input-buf-depth byte
	var d := Protocol.decode_self_state(b)
	assert_eq(int(d["input_buf_depth"]), -1, "absent depth byte -> -1 sentinel (loop stays idle)")
```

- [ ] **Step 2: Run** `--filter=self_state` — expect the two new tests FAIL (too many args / missing key).

- [ ] **Step 3: Implement**

`protocol.gd` line 19:
```gdscript
const VERSION := 4   # 4: SELF_STATE gains a trailing input-buf-depth byte (tick-lead netcode, 2026-07-05)
```

`encode_self_state`: append parameter `input_buf_depth: int = 0` (after `sprint_locked: bool = false`); before `return buf.data_array` append:
```gdscript
	# Tick-lead netcode (docs/specs/netcode-tick-lead.md): the per-client InputBuffer depth sampled
	# right after this tick's drain. The owner client nudges its input-production clock to hold this
	# at TickLead.TARGET, so starvation/coalescing (the wandering reconcile-replay length -> the ~1 Hz
	# movement micro-snap) become rare. Owner-only, appended last so older decoders ignore it.
	buf.put_u8(clampi(input_buf_depth, 0, 255))
```

`decode_self_state`: before the `return`, append:
```gdscript
	var input_buf_depth := -1   # -1 sentinel: absent -> tick-lead loop stays idle (never mis-corrects)
	if r.get_available_bytes() > 0:
		input_buf_depth = r.get_u8()
```
and add `"input_buf_depth": input_buf_depth` to the returned dictionary.

`wire-protocol-registry.md`: header bullet → `**Protocol.VERSION = 4** (2026-07-05, SELF_STATE gains a trailing input_buf_depth byte for tick-lead netcode …)`; msg 22 row: append `input_buf_depth` to the trailing-optional list with the same date note. Keep prior version history lines if the file records them.

- [ ] **Step 4: Run** `--filter=self_state` → all PASS (existing truncation tests keep passing: they slice from a buffer that now has one more trailing byte — re-check each `b.resize(b.size() - N)` count still drops the bytes its comment claims; the sprint-locked-absent test now needs `- 2` → verify and fix comments/counts as needed).

- [ ] **Step 5: Commit** — `feat(net): SELF_STATE carries post-drain input-buffer depth (VERSION 4, tick-lead)`

---

### Task 4: Server — sample depth after drain, send it

**Files:**
- Modify: `server/server_main.gd` (`_step_movement` ~line 449; client dict init ~line 942; `encode_self_state` call ~line 851)

- [ ] **Step 1: Implement (three one-liners)**

In `_step_movement`, right after the `pop()`/starvation block (after line 452, before the `if inp != null:` validation), add:
```gdscript
		# Tick-lead: depth right after this tick's drain — what the owner client's clock loop tracks.
		c["input_buf_depth"] = c["input_buf"].size()
```

Client-dict init (line 942): add `"input_buf_depth": 0,` alongside `"last_input_tick": 0`.

`encode_self_state` call (line 851): append final arg `int(c["input_buf_depth"])`.

- [ ] **Step 2: Run the full suite** — `godot --headless --path . -- --test` → no regressions (server functional tests exercise `_step_movement`/snapshot paths).

- [ ] **Step 3: Commit** — `feat(server): report post-drain input-buffer depth on SELF_STATE`

---

### Task 5: Client — TickLead wiring (hold / extra input tick)

**Files:**
- Modify: `client/client_main.gd`

- [ ] **Step 1: Extract the per-input-tick block into `_produce_input_frame(ss)`**

Move lines 439–526 (from `_pred.predicted.is_downed = ss.is_downed` through `_client_tick += 1`, inclusive — the whole input-production body of the `elif deployed:` branch) verbatim (one indent shallower) into:

```gdscript
## One full input tick for the local pawn: gather intent, predict (movement + weapon), send the
## redundancy bundle, advance _client_tick. Extracted so the tick-lead loop can run it 0/1/2
## times per physics frame (hold / normal / catch-up) — see docs/specs/netcode-tick-lead.md.
func _produce_input_frame(ss: EntityState) -> void:
	# … moved lines 439–526, unchanged …
```

Replace the `elif deployed:` body with:

```gdscript
	elif deployed:
		# Tick-lead (docs/specs/netcode-tick-lead.md): 0 = hold (server buffer too full — let it
		# drain), 1 = normal, 2 = catch up (buffer too shallow). At most one whole-frame adjust
		# per physics frame; the 30->60 reconcile interpolation absorbs it below perception.
		var reps: int = _tick_lead.frame_repeats()
		for _rep in reps:
			_produce_input_frame(ss)
		if reps == 0:
			# Held frame: still drain accumulated mouse look into the controller so the camera
			# stays live — we skip producing/sending INTENT, not looking.
			var _held := _input_ctrl.gather(_settings)
		if _scene_built:
			_input_ctrl.capture_mouse()
		if _scene_built and _deploy_menu != null:
			_deploy_menu.visible = false
```

(The trailing `capture_mouse()` / deploy-menu-hide lines move out of the extracted block so they run once per frame, not per rep. **Verify against `client/input_controller.gd` first**: if look is applied outside `gather()` — e.g. in `_process`/event handlers — drop the `reps == 0` gather call entirely; if `gather()` also latches one-shot button edges (jump/toggle presses) that a discard would eat, drain look only via `drain_look()`-style access instead. Adapt to what the controller actually does; the invariant is: a held frame must not lose look *or* eat buffered button edges.)

- [ ] **Step 2: Instance + feed + reset**

Near the other predictor members (`_pred`, `_wpred` declarations): `var _tick_lead := TickLead.new()`.

End of `_handle_self_state` (~line 1407), append:
```gdscript
	# Tick-lead: feed the post-drain buffer depth to the input-clock loop. Owner pawn only —
	# skip while seated (server-slaved; driver axes flow via last_input regardless) and ignore
	# the -1 absent sentinel from old/short packets.
	var _ibd := int(d.get("input_buf_depth", -1))
	if _ibd >= 0 and _in_vehicle() < 0:
		_tick_lead.on_depth(_ibd)
```

In the deploy/respawn reset path (the function containing line 1313 `_pos_err = Vector3.ZERO` — the same place both spawn paths reset prediction, per the G1 fix), add:
```gdscript
	_tick_lead.reset()   # buffer refills from scratch on deploy; stale phase would mis-adjust
```

- [ ] **Step 3: Feel-gate meter** — extend the 1 Hz `[client-dbg]` print (~line 1101) with ` lead_d=%d holds=%d extras=%d` using `_tick_lead.last_depth`, `_tick_lead.holds`, `_tick_lead.extras`.

- [ ] **Step 4: Run full suite + loopback smoke**

`godot --headless --path . -- --test` → 0 failed. Then `ci/connect_smoke_test.sh` (real server + rendered-path client loopback) → passes, `[client-dbg]` line shows `lead_d` settling at 2 and holds/extras staying near-zero on loopback (no jitter locally — the loop should be quiet).

- [ ] **Step 5: Commit** — `feat(client): tick-lead input-clock loop (hold/extra input frames, deploy reset, dbg meter)`

---

### Task 6: Fleet gate on game2 (spec test plan #3)

**Files:**
- Create: `docs/gate-evidence/2026-07-05-tick-lead-fleet.md`

- [ ] **Step 1:** Run the 128-bot gate **in tmux** (session runs on game2; teardown SIGKILLs bg tasks): `docker/stress.sh` / `docker/run-*-gate.sh` per current gate runbook, conquest_town.
- [ ] **Step 2:** Assert: tick budget unchanged (snap/tick within budget), telemetry `starvation` not regressed (bots don't run the loop — this is a no-regression + wire-cost check), zero SCRIPT ERROR.
- [ ] **Step 3:** Write the evidence file (numbers + command lines + host) and commit — `test(gate): tick-lead fleet evidence (128 bots, game2)`.

---

### Task 7: Docs + land

- [ ] **Step 1:** Spec status line → `**Status:** implemented (2026-07-05) — closing feel gate: owner playtest pending`. Note the feel gate explicitly: deterministic + fleet proof done; owner playtest is the closing gate (spec §Test plan #4).
- [ ] **Step 2:** Update `docs/TASKS.md` / `docs/HANDOVER.md` (whichever tracks in-flight work) — tick-lead implemented, owner feel-gate pending.
- [ ] **Step 3:** Full suite one last time (`--test`, expect ~1259+new / 0), then merge to master, push (AGENTS.md §11). Update auto-memory (tick-lead status).

---

## Self-review notes

- Spec coverage: signal byte (Task 3/4), control loop (Task 1), client pacing integration + owner-only gating + vehicle/bot exclusion (Task 5), test plan #1 (Task 1), #2 (Task 2), #3 (Task 6), #4 owner playtest = explicitly out of my hands, recorded in Task 7. Registry + VERSION bump same commit as the byte (Task 3). Deadzone narrowing: explicitly NOT touched (spec: separate step).
- Types consistent: `TickLead.TARGET/GAIN/on_depth/frame_repeats/reset/holds/extras/last_depth` used identically in Tasks 1, 2, 5.
- Known judgment points flagged inline: truncation-count check in existing protocol tests (Task 3 Step 4), input-controller look/edge semantics on held frames (Task 5 Step 1), jitter-probability tuning honesty rule (Task 2 Step 2).
