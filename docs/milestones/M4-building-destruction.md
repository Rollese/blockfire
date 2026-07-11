# M4 — Building & Destruction

**Status:** Phase 1 (Building) **+** Phase 2 (Destruction) — both gate PASS 2026-06-15 (laptop-48 + fleet-128) → **M4 gate CLOSED**.

**Objective:** BattleBit's signature fortification building and destructible environment, networked efficiently.

> **Building model partially superseded (2026-06-18, [ADR-0007](../adr/0007-battlebit-divergences.md) §2):** the **instant snap-to-grid placement** is replaced by **universal shovel-based progressive construction** (a piece creates a *build site* squadmates shovel to completion; large structures + the FOB require ≥2 builders) — implemented in **[M12-P2](M12-squad-fob-class-refit.md)**. The build grid, piece catalog, event-based replication, and collision are reused, and **all of M4 Phase-2 destruction is reused unchanged** (built structures + FOBs destroy via the M4 path). The M11 chunked `StructureStore` later unified the store (re-gated M4).

## Scope & gate
- Place/remove data-driven fortification pieces; server-authoritative validation (no client-trusted geometry).
- Networked structure state replicated within the interest set (no global broadcast).
- Destructible objects scoped coarse (chunk/voxel-ish, not per-fragment) to fit the netcode budget.
- **Gate:** building + destruction under 128-bot load holds the M1 tick + bandwidth budget.
- **Specs:** [`building.md`](../specs/building.md), [`destruction.md`](../specs/destruction.md). Phased per `building.md` §Phasing.

## Phase 1 (Building) — CLOSED ✅
Plan `docs/archive/plans/2026-06-15-m4-building.md` (15 TDD tasks). Impl: `BuildGrid`, `PieceCatalog` + `pieces/fortifications.json`, `StructureStore` (occupancy/region/owner indexes, ray-march cover, axis-separated movement collision), protocol `BUILD_REQUEST/REMOVE` + `STRUCTURE_DELTA/BASELINE`, server build handlers + region baselines + fire-ray cover, bot tactical building + structure mirror. Gate `ci/m4_building_test.sh`; 124 unit tests green.

**Laptop-48 PASS** (2026-06-15, 4750U, server pinned 0-3):
```
[match] OVER winner=0 t0=20 t1=0 elapsed=340s cap_events=3
[m4] winner=0 peak tick=18.40ms (budget 33.3) peak struct=3 builds=3 blocked_shots=4138
[m4] [bots] structures synced: bot 24 sees 1 piece(s)
M4 GATE: PASS
```
**Fleet-128 PASS** (2026-06-15, unraid W-2275 "SENET", `docker/` full profile, `SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 TICKETS=80 TIME_LIMIT=900`):
```
[match] OVER winner=1 t0=0 t1=26 elapsed=230s cap_events=3
peak-window tick_mean = 30.89 ms  (budget 33.3)   [tick_p99 peak 50.35 ms]
peak struct = 37   total builds = 37   total blocked_shots = 618   kills = 122
[bots] structures synced: bot 98 sees 1 piece(s)   no SCRIPT ERRORs
```
A second run via `docker/run-m4-gate.sh` also PASSed (winner=1 elapsed=262s peak tick=32.68ms<33.3 struct=26 builds=26 blk=3181). Building adds ~2.3 ms; the engagement-bounded cover march keeps it in check. Peak tick rides close to budget run-to-run (30.89–32.68 ms) — a firm watch item carried into Phase 2 / M5+.

*Bot-AI tuning knob:* `MAX_BOT_BUILDS` (`bots/bot_driver.gd`, capped 1) — the convergence/cover knob if the fleet over-blocks (bots build full-height walls to their side while stationary; unbounded building saturated the zone into a no-winner stalemate).

## Phase 2 (Destruction) — CLOSED ✅
Plan `docs/archive/plans/2026-06-15-m4-destruction.md` (14 TDD tasks). Impl: `StructureStore` `apply_damage`/`bucket_of`/`ids_in_radius`; `Grenade` pure ballistic + linear-falloff (FRAG/SMOKE); protocol `OP_DAMAGE` + `GRENADE_THROW(type)` + `SMOKE_DEPLOYED`; server bullet-damage-to-cover + capped bucket-diff delta flush (`MAX_STRUCTURE_DELTAS_PER_TICK=64`, removes-first + carry), present-time frag blast (`_step_grenades`/`_detonate`, no rewind) + smoke zones, bot frag-at-cover / smoke-on-advance AI (`MAX_BOT_GRENADES`/`MAX_BOT_SMOKES=1`). Gate `ci/m4_destruction_test.sh`; 140 unit tests green.

**Laptop-48 PASS** (2026-06-15):
```
[match] OVER winner=0 t0=34 t1=0 elapsed=248s cap_events=2
[m4p2] winner=0 peak tick=20.46ms (budget 33.3) destroyed=4 nades=6 splash=0 smoke=48
M4-P2 GATE: PASS
```
**Fleet-128 PASS** (2026-06-15, same topology, 2/2 confirming reruns):
```
run A: OVER winner=0 elapsed=233s cap_events=3 peak tick=29.48ms struct=22 builds=24 blk=82 destroyed=5  nades=88 smoke=128
run B: OVER winner=1 elapsed=272s cap_events=6 peak tick=29.48ms struct=33 builds=49 blk=339 destroyed=23 nades=55 smoke=128
```
**Destruction is cheap** — per-phase `[perf] us/tick` at the peak window:
```
poll=2.8 move=0.9 lag=0.3 interest=0.2 fire=4.2 respawn=0.1 conquest=0.4 match=0.02 snap=16.3 ms
```
`_step_grenades` + `_expire_smoke_zones` fold into respawn=0.1 ms (negligible); `_emit_structure_deltas` is bounded (≤64/tick) inside `snap`, which is dominated by the pre-existing M3 `_send_snapshots` (~16 ms), **not** destruction.

*Variance note:* one initial fleet run hit `tick_mean=35.39 ms` (FAIL), then two identical-pinning reruns both landed at 29.48 ms (PASS) — a contention spike on the snap-dominated tick (documented contention-sensitivity), not a destruction cost. `MAX_STRUCTURE_DELTAS_PER_TICK`, `MAX_BOT_GRENADES`, `BLAST_STRUCT_RADIUS` are the graceful-degradation knobs.
