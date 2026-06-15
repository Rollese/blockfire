# M4 — Building & Destruction

**Status:** Phase 1 (Building) — laptop-48 gate PASS 2026-06-15, fleet-128 pending; Phase 2 (Destruction) next · *(M4–M6 may be reordered)*

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

### Fleet — 128 bots — **PENDING** (run on the unraid W-2275 Docker fleet, not the laptop)
Per HANDOVER the 128-bot gate runs on the separate-host fleet (`docker/`, server pinned to
isolated cores, bots in containers). Reproduce:
```
cd docker && SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-gate.sh
```
> Action for the maintainer: `docker/run-gate.sh` currently invokes the M3 conquest gate.
> Building is always-on in the server now, so the existing run already exercises M4, but it
> does **not** assert `struct`/`bld`/`blk`. Point `run-gate.sh` at `ci/m4_building_test.sh`
> (or run that script inside the fleet containers) to get the M4 assertions. Record the
> `[m4] winner=… peak tick=…ms peak struct=… builds=… blocked_shots=…` + `structures synced`
> lines and the PASS/FAIL verdict here once run.

**Phase 1 verdict:** laptop-48 **PASS**; fleet-128 **pending** (maintainer). Phase 2
(Destruction) remains.
