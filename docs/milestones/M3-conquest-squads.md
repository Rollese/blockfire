# M3 — Conquest + Deploy/Respawn + Squads

**Status:** ✅ DONE (2026-06-15) — full 128-bot gate PASS on the separate-host bot fleet (peak tick 28.6 ms < 33.3 ms budget) after the snapshot-cost optimization. See Gate evidence.

**Objective:** A complete, winnable match loop.

> **Partially superseded (2026-06-18, [ADR-0007](../adr/0007-battlebit-divergences.md) §2):** the ratified **"spawn on any alive squadmate"** primary forward spawn is replaced by a **squad-leader-built FOB** (squadmate-rally retained only as a *fallback*; FOB spawning is disabled while an enemy is in its vicinity). Implemented in **[M12](M12-squad-fob-class-refit.md)** before/with the M7 client. The rest of M3 (Conquest capture/ticket machinery, squads, deploy/respawn) stands.

## Scope
- **Conquest** mode: capture points, ticket bleed, team scores, win condition.
- Data-driven map: flag/capture-point layout, team spawns (`maps/`).
- Deploy screen, respawn timer, spawn on points/squad.
- **Squad system**: create/join squad, squad list UI, squad leader, spawn on squadmate.
- Bot AI: path to nearest objective, engage visible enemies, respawn.

## Gate
A **full bot-only Conquest match runs start → win at 128 players**: bots path to nearest objective, fight, capture, respawn; a team reaches the win condition. Match observable by a human spectator client. Codified in `ci/m3_conquest_test.sh` (asserts: valid winner · ≥1 capture · ended via tickets, not the time fail-safe · peak-window server tick < 33.3 ms).

## Gate evidence (run 2026-06-15)

**Gameplay: PASS at 128 players.** A full bot-only Conquest match ran start→win at 128 bots:
```
[match] OVER winner=0 t0=6 t1=0 elapsed=217s cap_events=2
```
Valid winner declared; points captured (`cap_events=2`); match ended via ticket depletion at 217 s game-time (< 600 s time fail-safe). The three **gameplay** gate criteria pass at full player count.

**Tick budget: PASS at 128 — on the separate-host fleet, after optimization.** Run on the unraid **Xeon W-2275** with the dedicated server pinned to isolated physical cores (`cpuset 0,1,14,15`) and the 128-bot fleet in Docker containers on the rest (`docker/`, run-from-source):
```
[match] OVER winner=0 t0=31 t1=0 elapsed=289s cap_events=7
[m3] winner=0 elapsed=289s cap_events=7 peak-window mean tick=28.62ms (budget 33.3)
M3 DOCKER GATE: PASS
```
All four criteria green at 128 players: valid winner, captures, ended via tickets, peak tick **28.62 ms** with ~4.7 ms margin.

**Getting there — the tick was first a real single-thread/algorithmic ceiling, not just laptop thermals.** Isolating the fleet on the W-2275 (uncontended, cool, `starv≈0`) still measured **~49 ms** at 128 players. Per-phase profiling (`[perf]` telemetry) showed `_send_snapshots` was **~88% of the tick** — O(N²) delta-encode when players cluster (every client sees ~everyone). Two GDScript optimizations (no GDExtension needed):
- **`SNAPSHOT_STRIDE=2`** — send each client a snapshot every 2nd tick (15 Hz; client interpolation smooths it). Halved per-tick encode.
- **`MAX_SNAPSHOT_ENTITIES=32`** — relevance cap: each snapshot carries the 32 most-relevant entities, **enemies first** then nearest teammates (a naive nearest-N hid foes behind a wall of teammates and killed bot combat — a real bug caught in validation), self always kept.

Effect: peak-window tick **95 ms → 28.6 ms**, bandwidth 29 → ~9 Mbit/s. Tradeoffs (deliberate, tunable): 15 Hz snapshot rate and a 32-entity relevance budget per client — standard 128-player netcode practice.

**The dev laptop (4750U) cannot host the 128-bot gate itself** — it thermally throttles under co-located load (package 95 °C, tick 52–106 ms; the M2 gate also fails on it today despite its recorded 30 ms PASS). That's a host limit, not M3: the same code does **48 bots at ~20 ms** on the laptop and **128 bots at 28.6 ms** on the fleet. Earlier laptop FAIL for the record: `peak-window mean tick=105.98ms`.

**Full gate PASS at 48 bots on the laptop, 2026-06-15:**
```
[match] OVER winner=0 t0=31 t1=0 elapsed=253s cap_events=3
M3 GATE: PASS  (peak-window mean tick=19.73ms, budget 33.3)
```

### How the match is decided
On the symmetric `proving_grounds` map, mirror-image bots hold their backfield points (1–1, no flag deficit), so the match is decided by **combat attrition** (death-tickets) rather than flag bleed; the flag-capture and bleed machinery is implemented and exercised (captures occur) but does not swing a symmetric bot match. A real flag-bleed swing would need flank/spread bot AI — tracked as a follow-up. Bot combat required three fixes found during validation (see `docs/specs/m3-bot-convergence-fix.md`): map-center→nearest-self objective (so points are captured), **reload** (server-time burst pacing — without it combat died after one magazine), and **hold-still-to-shoot** (the server penalises moving shooters; this lifted hit-rate ~0.03→~0.2 and made attrition decisive).

## How to reproduce the 128-bot gate
On the fleet host (unraid W-2275), with the repo at `/mnt/app/blockfire`:
```
cd docker && docker build -t blockfire:latest -f Dockerfile ..
SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 TICKETS=80 ./run-gate.sh
```
See `docker/README.md`. On the laptop, the 48-bot gate is `ci/m3_conquest_test.sh` (pass `BOTS=48`).

## Follow-ups (non-blocking)
- The 4750U laptop can't run the 128-bot gate (thermal); use the fleet for full-count perf. M4/M5 add tick cost — re-profile `_send_snapshots` if it regresses, and the 14900K dedi (when ready) gives single-thread headroom.
- Symmetric bot matches are decided by combat attrition, not flag bleed (mirror bots → no flag deficit). Real bleed needs flank/spread bot AI — see `docs/specs/m3-bot-convergence-fix.md`.

## Specs
- Conquest/squads/spawning/bot-AI: `docs/specs/m3-conquest-squads.md` · bot decisiveness fixes: `docs/specs/m3-bot-convergence-fix.md`
