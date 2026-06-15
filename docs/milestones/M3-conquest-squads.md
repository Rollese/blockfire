# M3 — Conquest + Deploy/Respawn + Squads

**Status:** gameplay ✅ (2026-06-15) · **128-bot tick-budget gate: BLOCKED (hardware)** — see Gate evidence.

**Objective:** A complete, winnable match loop.

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

**Tick budget: FAIL at 128 — hardware-bound, not an M3 regression.**
```
[m3] winner=0 elapsed=217s cap_events=2 peak-window mean tick=105.98ms (budget 33.3)
M3 GATE: FAIL  (peak-window tick over budget)
```
This 15 W mobile Ryzen (4750U) thermally throttles under sustained 128-bot load (package 95 °C, cores ~1.4 GHz), so the single-threaded server tick blows the budget. Evidence it is the **host**, not M3:
- The **M2 gate also fails on this box today** (~54 ms) despite its recorded 30.01 ms PASS on 2026-06-14 — a same-day environmental swing.
- M3's per-tick cost measured **identical to M2** (the M3 fire pre-filter adds nothing); at 32–48 bots the tick is 12–20 ms, comfortably under budget.
- See `blockfire-gate-perf-hardware` memory and ADR-0001 (GDExtension escalation) / M8 (Docker bot fleet). The ratified fix is to run bots on a **separate host** so the server core runs uncontended; not available this session.

**Full gate PASS at a hardware-sustainable count (48 bots), 2026-06-15** — proves the loop is genuinely decisive end-to-end with all assertions green:
```
[match] OVER winner=0 t0=31 t1=0 elapsed=253s cap_events=3
[m3] winner=0 elapsed=253s cap_events=3 peak-window mean tick=19.73ms (budget 33.3)
M3 GATE: PASS
```

### How the match is decided
On the symmetric `proving_grounds` map, mirror-image bots hold their backfield points (1–1, no flag deficit), so the match is decided by **combat attrition** (death-tickets) rather than flag bleed; the flag-capture and bleed machinery is implemented and exercised (captures occur) but does not swing a symmetric bot match. A real flag-bleed swing would need flank/spread bot AI — tracked as a follow-up. Bot combat required three fixes found during validation (see `docs/specs/m3-bot-convergence-fix.md`): map-center→nearest-self objective (so points are captured), **reload** (server-time burst pacing — without it combat died after one magazine), and **hold-still-to-shoot** (the server penalises moving shooters; this lifted hit-rate ~0.03→~0.2 and made attrition decisive).

## Outstanding to fully close M3
- Validate the **128-bot tick budget on the separate-host bot fleet** (server uncontended) — the only failing gate criterion. Hardware/ops item, not gameplay.

## Specs
- Conquest/squads/spawning/bot-AI: `docs/specs/m3-conquest-squads.md` · bot decisiveness fixes: `docs/specs/m3-bot-convergence-fix.md`
