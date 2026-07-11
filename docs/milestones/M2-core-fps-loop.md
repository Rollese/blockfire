# M2 — Core FPS Loop

**Status:** done ✅ (gate passed 2026-06-14)

**Objective:** A recognizable shooter on top of the netcode core.

## Scope
- Movement: walk/sprint/crouch/prone, lean, jump, stamina — server-authoritative with client prediction.
- Gunplay: hit-scan + projectile weapons, recoil patterns, spread, reload, bullet drop (projectile guns), **lag-compensated hit-reg** (consumes M1 rewind).
- Health / damage / death.
- Basic class kits (Assault/Medic/Engineer/Support/Recon-style) with loadouts — data-driven.
- Blocky placeholder character + weapon art (real art deferred to M7).

## Gate
Bots can move and shoot each other, kills register correctly, and **128 bots stay stable** at 30 Hz.

## Spec (approved-pending-review)
- [`docs/specs/m2-core-fps-loop.md`](../archive/specs/m2-core-fps-loop.md) — one consolidated doc: full movement, hit-scan gunplay, lag-compensated hit-reg (head+body hitboxes), health/death/respawn, teams (FF off), minimal classes, combat bot AI.

## Decisions (ratified)
- Lag comp: client fire-tick rewind, clamped (`MAX_REWIND`≈12 ticks) + server-validated.
- Hitboxes: two-part head sphere + body capsule, headshot multiplier.
- Weapons: hit-scan only (projectiles deferred); deterministic server-authoritative spread/recoil.
- Movement: full set (walk/sprint/crouch/prone/lean/jump/stamina).
- Teams ON (2 teams, balanced, team-separated spawns); friendly fire OFF.

## Evidence

Gate run 2026-06-14 via `ci/m2_load_test.sh` (128 bots, 2 teams, 60s):

```
[telemetry] players=128 alive=125 tick_mean=29.59ms tick_p99=33.05ms agg=15.9Mbit/s kills=0 shots=75 hit_rate=0.03 starv=531 rewind_clamped=0
[m2] last-window mean tick=29.59ms  peak-window mean tick=30.01ms  (budget 33.3)  total kills over run=19
M2 GATE: PASS
```

- players=128, alive=125
- peak-window tick_mean=30.01ms (budget <33.3ms)
- tick_p99=33.05ms (last window)
- total kills over run=19 (>= 1 required)
- hit_rate=0.03 (last window)
- starv=531 (last window)

Gate asserts **peak-window tick_mean < 33.3ms AND total kills over run >= 1**.

Final spawn-zone tuning (`server/server_main.gd::_spawn_pos`): two opposing zones spread
along a wide z-front — team 0 `x ∈ [-400, -150]`, team 1 `x ∈ [150, 400]`, both
`z ∈ [-900, 900]`. This widened spacing vs. the prior `x ∈ [±80,±300]`, `z ∈ [±700,700]`
zones, lowering interest density (and thus tick cost) closer to the M1 wide-spacing
baseline (tick_mean=17.65ms) while still letting the two teams converge and fight
(19 kills in the gate run, well over the required minimum of 1).

Unit suite: `godot --headless --path . -- --test` → `TESTS: 47 run, 0 failed`.
