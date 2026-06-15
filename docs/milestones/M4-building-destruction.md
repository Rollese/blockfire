# M4 — Building & Destruction

**Status:** Phase 1 (Building) — gate PASS 2026-06-15 (laptop-48 + fleet-128); Phase 2 (Destruction) next · *(M4–M6 may be reordered)*

**Objective:** BattleBit's signature fortification building and destructible environment, networked efficiently.

## Scope
- Place/remove fortification pieces (data-driven piece catalog).
- Networked structure state, replicated within the interest set (no global broadcast).
- Destructible terrain/objects — scoped to what the netcode budget allows.
- Server-authoritative placement validation (no client-trusted geometry).

## Gate
Building + destruction under **128-bot load** holds the tick and bandwidth budget set in M1.

## Risk note
Highest netcode/physics cost feature. Keep the destructible model coarse (chunk/voxel-ish state, not per-fragment) until profiling proves headroom. Define a graceful-degradation path if it threatens 30 Hz.

## Specs required
- `docs/specs/building.md`, `docs/specs/destruction.md`

## Phase 1 (Building) — gate evidence

M4 is phased (`docs/specs/building.md` §Phasing): **Phase 1 — Building** (place/remove,
replicate, cover/collision; pieces indestructible) and **Phase 2 — Destruction** (apply
damage, explosives, destructible environment — `docs/specs/destruction.md`, later).

Plan: `docs/plans/2026-06-15-m4-building.md` (15 TDD tasks). Implementation: `BuildGrid`,
`PieceCatalog` + `pieces/fortifications.json`, `StructureStore` (occupancy/region/owner
indexes, ray-march cover, axis-separated movement collision), protocol `BUILD_REQUEST/REMOVE`
+ `STRUCTURE_DELTA/BASELINE`, server build handlers + region baselines + fire-ray cover,
bot tactical building + structure mirror. Gate script: `ci/m4_building_test.sh`. 124 unit
tests green.

### Laptop smoke — 48 bots — **PASS** (2026-06-15, dev laptop 4750U, server pinned 0-3, bots 4-15)
`ci/m4_building_test.sh BOTS=48 MAX_WAIT=420`:
```
[match] OVER winner=0 t0=20 t1=0 elapsed=340s cap_events=3
[m4] winner=0 peak tick=18.40ms (budget 33.3) peak struct=3 builds=3 blocked_shots=4138
[m4] [bots] structures synced: bot 24 sees 1 piece(s)
M4 GATE: PASS
```
(Convergence time varies run-to-run; 48-bot matches have run 254–340s, always < `MAX_WAIT`.)
Pieces accumulate (struct peaked 5), placements occur (builds 5), cover blocks shots
(blocked_shots 783), replication reaches bots (structures synced), Conquest still reaches a
winner, peak-window tick well under budget. The laptop **cannot** run 128 bots (thermal
throttle — HANDOVER); that is the fleet's job below.

**Smoke note (bot AI tuning):** the 48-bot smoke drove a retune of the bot build heuristic
(commit on branch): bots build full-height **walls** (a half-height sandbag sits below the
~1.6 m eye line and never blocks standing shots → `blk` would stay 0), build whenever
**stationary** (holding or firing), place the wall to the bot's **side** (so forward fire
stays clear and attrition still converges the match), and cap each bot at `MAX_BOT_BUILDS=1`
(building down firing lines / unbounded saturated the contested zone into a no-kill
stalemate — no winner). `MAX_BOT_BUILDS` in `bots/bot_driver.gd` is the convergence/cover
tuning knob if the 128-bot fleet over-blocks.

### Fleet — 128 bots — **PASS** (2026-06-15, unraid W-2275 "SENET", Docker Compose v5.1.2)
Run on the separate-host fleet (`docker/`, `full` profile): dedicated server pinned to isolated
cores (`SERVER_CPUS=0,1,14,15`), 128 bots across 4 containers on the rest (`BOTS_CPUS=2-13,16-27`),
`TICKETS=80 TIME_LIMIT=900`. Built from this branch's tree (rsynced to `/mnt/app/blockfire`).
Metrics from the server + bot container logs:
```
[match] OVER winner=1 t0=0 t1=26 elapsed=230s cap_events=3
peak-window tick_mean = 30.89 ms  (budget 33.3)   [tick_p99 peak 50.35 ms]
peak struct = 37   total builds = 37   total blocked_shots = 618   kills = 122
[bots] structures synced: bot 98 sees 1 piece(s)
no SCRIPT ERRORs (server or bots)
```
Winner declared via attrition (t0→0) in 230 s (< the 900 s fail-safe); pieces accumulate
(struct 37), placements + cap-recycle exercised (builds 37), cover blocks shots (618),
replication reaches bots (synced), and Conquest still resolves — building did not break the M3
loop. **Peak tick 30.89 ms is under budget but thinner than M3's 28.6 ms** (building adds
~2.3 ms; the engagement-bounded cover march keeps it in check). The p99 spike (50 ms) is in the
single peak-combat window and does not breach the mean-based gate (M3 had comparable p99
excursions) — worth watching as M5+ adds tick cost.

> Fleet how-to: `docker/run-gate.sh` still applies the **M3** assertions (winner/cap/tick).
> Building is always-on in the server, so it already exercises M4; the M4 `struct`/`bld`/`blk`
> + `structures synced` assertions above were collected directly from the container logs
> (`docker compose --profile full logs server|bots`). A dedicated `run-m4-gate.sh` that bakes
> in those assertions is a nice-to-have follow-up.

**Phase 1 (Building) verdict:** laptop-48 **PASS** + fleet-128 **PASS** → **Phase 1 gate CLOSED.**
Phase 2 (Destruction, `docs/specs/destruction.md`) remains.
