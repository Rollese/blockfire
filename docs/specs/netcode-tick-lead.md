# Spec: Explicit tick-lead management (movement-feel netcode fix)

**Status:** implemented (2026-07-05) — deterministic tests (`tests/tick_lead_test.gd`: control law +
closed-loop jitter/drift sim, edge events 248→96), live loopback (lead_d converges to 2, then zero
adjusts) and 128-bot fleet gate (PASS, `docs/gate-evidence/20260705-213626-ticklead.txt`) all done.
**Closing feel gate: owner playtest pending** (jump-apex micro-jitter + per-reconnect variability
gone; `[client-dbg]` now prints `lead_d/holds/extras` as the meter). Deadzone narrowing (0.12→?)
remains a separate follow-up step per §Interaction. Originally proposed 2026-07-05 after the M7
playtest rounds 4–5 diagnosis
(`docs/sessions/2026-07-05-m7-playtest-round4-5.md` → "Key diagnosis — movement snap").
Prediction-bearing → this spec precedes the code (AGENTS.md §4). Feel-gated → the closing
gate is an **owner playtest**, proven first deterministically on game2 (AGENTS.md §10).

## Problem (root cause, confirmed in code)

The residual movement micro-snap (most visible at the jump apex and stamina boundaries, and
varying per reconnect — vertical one join, horizontal the next) is **unmanaged prediction lead**:

- The client produces one input frame per client tick at 30 Hz, tagged with a **local**
  `_client_tick` that starts at 0 and only increments (`client_main.gd`). There is **no
  tick-lead / jitter-buffer management.**
- The server buffers frames per client in `InputBuffer` (`shared/net/input_buffer.gd`,
  `MAX_DEPTH=4`) and drains **one per sim tick**, stamping each snapshot header with
  `last_input_tick` = the `client_tick` it just consumed (`server_main._step_movement`).
- The client reconciles by replaying every buffered frame with `tick > last_input_tick`
  (`Prediction.reconcile_full`). The replay length **is** the prediction lead
  `≈ _client_tick − last_input_tick`.

The lead equals whatever depth the server's input buffer happens to settle at for that
connection — set by the initial send/drain phase offset plus network jitter, and never
corrected. Jitter pushes the buffer across its edges: **starvation** (empty → server reuses
the last frame, `_tele.starvation++`) and **coalescing** (a recovered burst exceeds `MAX_DEPTH`
→ the oldest frame is dropped, `InputBuffer.coalesced++`). Each event skips or repeats one
input tick, so the reconcile lands on a slightly different authoritative position and the
client eases a correction — the ~1 Hz snap. Widening the reconcile deadzone (0.04→0.12,
`bca2069`) masks the amplitude; it does not remove the cause.

## Goal

Hold the server's per-client input buffer at a small, **stable** target depth so starvation and
coalescing become rare and the reconcile-replay length stops wandering. Standard adaptive
tick-sync (Quake3 / Overwatch "input buffer clock adjust"): the client nudges its input
production clock by tiny amounts to keep the far-side buffer near target.

## Design

**Target depth** `TICK_LEAD_TARGET = 2` frames (~66 ms at 30 Hz): one frame of slack above
empty (survives an isolated late packet) while staying well under `MAX_DEPTH=4` (headroom for a
redundancy-recovered burst before coalescing).

**Server → client signal (wire).** Extend the per-owner `SELF_STATE` with the buffer occupancy
sampled at the tick the snapshot's `last_input_tick` was drained: one trailing `u8`
`input_buf_depth` (0..MAX_DEPTH). Append-only after the existing trailing bytes (current order:
`… stamina, vel_y, grounded, vaulting, vault_tick, regen_cooldown` — see the round-4/5 session
log) and read only if bytes remain, exactly like the vault/regen bytes. **Because it is
prediction-bearing, bump `Protocol.VERSION` and register it in
`docs/specs/wire-protocol-registry.md`** in the same commit (SELF_STATE keeps its msg id; the
field is new). Depth is free server-side: `c["input_buf"].size()` immediately after the drain.

**Client control loop (owner client only — bots never reconcile).** Keep a fractional
`_tick_phase` accumulator. On each `SELF_STATE`:

```
e = input_buf_depth - TICK_LEAD_TARGET      # +ve: buffer too full (client ahead)
_tick_phase += clamp(e, -1, 1) * TICK_LEAD_GAIN     # GAIN ≈ 0.05, slow
```

In `_physics_process`, before producing the frame:

```
if _tick_phase >= 1.0:   _tick_phase -= 1.0; skip_this_input_tick()   # hold: don't advance _client_tick / don't send — let the server drain the surplus
elif _tick_phase <= -1.0: _tick_phase += 1.0; emit_extra_input_tick() # catch up: advance twice this frame
```

Corrections are integer frames, at most one per physics frame, a few per second at most (GAIN
small) — below the perceptual threshold and absorbed by the existing 30→60 reconcile
interpolation. Converges to target and self-corrects drift without oscillating. No gameplay
rule logic moves to the client — it only paces *when* it samples/sends intent (AGENTS.md §7).

**Interaction with existing smoothing.** The reconcile deadzone/ease and `_pos_err` path stay;
this removes the *source* of the wandering correction so the deadzone can eventually be
narrowed back (validate before changing it — separate step).

## Test plan (deterministic first, per AGENTS.md §10)

1. **Control-law unit test** (`tests/tick_lead_test.gd`): drive the accumulator with scripted
   `input_buf_depth` sequences; assert it converges to `TICK_LEAD_TARGET`, emits hold/catch-up at
   the expected cadence, never more than one adjust per frame, and is stable (no oscillation) on
   a constant-at-target input.
2. **Loopback jitter integration**: feed the server variable packet-arrival timing; assert the
   per-client buffer depth converges to `target ± 1` and `starvation` + `coalesced` counters drop
   markedly vs. a baseline run with the loop disabled.
3. **Fleet gate** (`docker/run-*-gate.sh`, 128 bots on game2): tick budget unaffected
   (`snap`/tick within budget), telemetry `starvation`/`coalesced` down; record evidence in
   `docs/gate-evidence/`.
4. **Feel gate (closing):** owner playtest — the jump-apex micro-jitter and the per-reconnect
   variability are gone; walking/sprint stay smooth. Re-measure with a temporary reconcile meter
   (peak correction magnitude/vector) on the `[client-dbg]` 1 Hz line, as in round 5.

## Risks

- **Over-correction / oscillation** if `GAIN` is too high or the loop reacts to single-sample
  noise — keep GAIN small, clamp the per-sample error, and smooth. Start conservative.
- **Owner-client only** — gate the loop behind "is the local predicted pawn" so bots (which do
  not reconcile) and passenger/gunner seats (server-slaved) are unaffected.
- **Do not tune by live trial-and-error** — land the deterministic tests + fleet evidence first,
  then hand the client to the owner for the feel gate (the M5-P1 lesson).

## Out of scope

Snapshot-rate / interest changes, the server drain cadence, and the reconcile-smoothing model
itself. This spec adds only the closed loop that stabilizes the input-buffer depth.
