# Blockfire Task Board

Canonical source of truth for what's being worked on. Claim a task (set owner + `in-progress`) before starting. See `AGENTS.md` for the working agreement.

**Status legend:** `todo` · `in-progress` · `blocked` · `review` · `done`

## Milestone index

| # | Milestone | Status | Gate (must pass to close) |
|---|---|---|---|
| M0 | [Foundations & decisions](milestones/M0-foundations.md) | **done ✅** | Empty client connects to empty server via custom message layer; bot driver connects 1 bot. |
| M1 | [Netcode core](milestones/M1-netcode-core.md) | **done ✅** | Bot fleet sustains 128 connected pawns @ 30 Hz on one Linux host within CPU/bandwidth budget. Gate run 2026-06-13: 128 players, tick_mean=17.65ms (budget <33.3ms) — PASS. See evidence in milestone doc. |
| M2 | [Core FPS loop](milestones/M2-core-fps-loop.md) | **done ✅** | Bots move + shoot each other; kills register; 128 bots stable. Gate run 2026-06-14: 128 players, peak-window tick_mean=30.01ms (budget <33.3ms), total kills=19 — PASS. See evidence in milestone doc. |
| M3 | [Conquest + respawn + squads](milestones/M3-conquest-squads.md) | **done ✅** | Bot-only Conquest match runs start→win at 128. Gate 2026-06-15 on separate-host fleet (unraid W-2275, server pinned, bots in Docker): `winner=0 elapsed=289s cap_events=7 peak tick=28.62ms<33.3` — PASS. Required a snapshot-cost fix (send staggering + enemy-prioritized relevance cap; `_send_snapshots` was 88% of the tick, O(N²)) — peak 95→28.6ms. 48-bot laptop gate also PASS (19.7ms). 88 unit tests green. See milestone doc. |
| M4 | [Building & destruction](milestones/M4-building-destruction.md) | **done ✅** | Phase 1 (Building) + Phase 2 (Destruction) both gate PASS 2026-06-15. Phase-2 fleet-128 (2/2 reruns): `winner valid elapsed=233/272s destroyed=5/23 nades=88/55 smoke=128 peak tick=29.48ms<33.3` — PASS. Destruction per-tick cost ~0.1ms (respawn phase); snap remains the dominant pre-existing cost. 140 unit tests green. See milestone doc. |
| M4.5 | [Combat depth & class identity](milestones/M4.5-combat-depth.md) | **done ✅** | **All three phases gated PASS on `game2`.** P1 (DBNO/revive/bandages) 2026-06-15; P2 (gadgets/RPG/penetration/attachments) 2026-06-16; P3 (ladders/vaulting/drop-shoot) 2026-06-16 (`winner=1 climbs=9 vaults=16 peak tick=23.46ms<33.3`). Body dragging deferred to M7 (per spec). 245 unit tests green. |
| M5 | [Vehicles (land + air)](milestones/M5-vehicles.md) | **in progress (P1 done ✅)** | **P1 (Land Vehicles + Substrate) CLOSED 2026-06-16** — fleet gate PASS on `game2` (`peak tick=23.67ms<33.3`, transport_m=930.8, enters=6; combat chain proven deterministically in `tests/vehicle_gate_test.gd`), `docker/srvlog-20260616-210141.log`. 309 unit tests green. **P2 (Air) next.** |
| M6 | [Voice (proximity + squad)](milestones/M6-voice.md) | todo | Voice works for human testers in a live match without breaking tick budget. |
| M7 | [Art pass + UX polish](milestones/M7-art-ux.md) | todo | End-to-end human playtest of a full Conquest match. |
| M7.5 | [Bot intelligence (tactical AI)](milestones/M7.5-bot-intelligence.md) | todo | Tactical, human-like, fair-play infantry bots (cover/stance, revive/resupply, attack/defend roles, grenades-vs-cover) usable as 128-player match-fillers; admin free-fly spectator + bot-AI debug overlay; bot-driver CPU scales to 128; Conquest reaches a winner; operator visual sign-off. |
| M8 | [Hardening & ops](milestones/M8-hardening-ops.md) | todo | Documented one-command stress run spins server + 128 bots in Docker. |
| M9 | [Online services (accounts, anti-cheat detection, matchmaking)](milestones/M9-online-services.md) | todo | Steam auth → skill-tier placement → matched into an official 128-slot server (with dynamic tier-merge); signed match reports update rating; a seeded cheat trace is flagged. |

> Milestones are **sequenced and gated**. Do not start a milestone before the previous gate passes. M4–M6 may be reordered but each remains independently gated.

## M4.5 Phase 1 (Survivability) — CLOSED ✅

Spec: [`docs/specs/combat-depth.md`](specs/combat-depth.md) (three-phase split). Plan: [`docs/plans/2026-06-15-m4.5-p1-survivability.md`](plans/2026-06-15-m4.5-p1-survivability.md) — 9 TDD tasks (DBNO/revive/bandages), executed via `subagent-driven-development`. **Gated PASS 2026-06-15** on the dedicated `game2` host. Design evolved during gating (immune-DBNO, latched revive, friendlies-always replication) — see the spec + milestone doc. **Next: P2 (gadgets/RPG/penetration/attachments) and P3 (movement) get their own plans.**

| Task | Owner | Status | Notes |
|---|---|---|---|
| M4.5-P1 brainstorm + spec | claude | done | `docs/specs/combat-depth.md` committed |
| M4.5-P1 implementation plan | claude | done | `docs/plans/2026-06-15-m4.5-p1-survivability.md` |
| M4.5-P1 execute (9 tasks) | claude | done | subagent-driven; Tasks 5 & 7 reviewed; immune-DBNO + latched-revive + friendlies-always added during gating |
| M4.5-P1 fleet 128-bot gate | claude | **done** | PASS on `game2` (14900KS): `downed=5 revives=3 winner=1 peak tick=22.58ms`; `docker/srvlog-20260615-211516.log`. Fleet testing moved off prod unraid → game2. |

## M4.5 Phase 2 (Combat Depth) — CLOSED ✅ (2026-06-16)

Spec: [`docs/specs/combat-depth.md`](specs/combat-depth.md) (P2 section). Plan: [`docs/plans/2026-06-15-m4.5-p2-combat-depth.md`](plans/2026-06-15-m4.5-p2-combat-depth.md) — 15 TDD tasks. **One plan, one fleet gate** (per spec). Built on a `m4.5-p2-combat-depth` branch via `subagent-driven-development` (Tasks 9, 10, 13 got review subagents — they touch the authoritative fire path / new entity ticks). Data-driven via `data/gadgets.json` + `data/attachments.json`. Penetration wires into `server_main._fire_shot` (not `combat.gd march()`, which lives on `StructureStore`); P1's immune-DBNO preserved — **no finishing**. Gate evidence: `docker/srvlog-20260616-003326.log`; milestone `docs/milestones/M4.5-combat-depth.md`.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M4.5-P2 implementation plan | claude | done | `docs/plans/2026-06-15-m4.5-p2-combat-depth.md` (15 tasks) |
| M4.5-P2 execute (15 tasks) | claude | **done** | subagent-driven; Tasks 9/10/13 two-stage reviewed; penetration + attachments + Gadget/RPG + C4/mines + medic/ammo tools + bot AI + gates. 214 unit tests green. |
| M4.5-P2 fleet 128-bot gate | claude | **done** | PASS on `game2`: `winner=1 elapsed=229s peak tick=25.77ms (<33.3)`; `rockets=8 c4=8 mines=2 heals=211 ammo=13 bags=27` (all ≥1), agg 16.5 Mbit/s. `pen` reported (unit-tested, not gated — needs a shot crossing a penetrable half-height sandbag). Laptop-48 smoke also PASS. Evidence `docker/srvlog-20260616-003326.log`. |

## M4.5 Phase 3 (Movement) — CLOSED ✅ (2026-06-16) → M4.5 COMPLETE

Spec: [`docs/specs/combat-depth.md`](specs/combat-depth.md) (P3 section). Plan: [`docs/plans/2026-06-16-m4.5-p3-movement.md`](plans/2026-06-16-m4.5-p3-movement.md) — 12 TDD tasks (ladder climbing, auto-vaulting, drop-shoot prevention). Built on the `m4.5-p3-movement` branch via `subagent-driven-development` (Tasks 6 & 9 two-stage reviewed — authoritative movement/fire path; branch HEAD verified after each reviewer). Movement rules live in `shared/sim/` (`Ladder`/`Vault` pure helpers + `SimLoop` orchestration) so a future M7 client can predict them; `climbing` replicated in state-byte bit 7 (`vaulting` deferred to M7). Gate evidence: `docker/srvlog-20260616-115725.log`; milestone `docs/milestones/M4.5-combat-depth.md`.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M4.5-P3 implementation plan | claude | done | `docs/plans/2026-06-16-m4.5-p3-movement.md` (12 tasks) |
| M4.5-P3 execute (12 tasks) | claude | **done** | subagent-driven; Tasks 6/9 two-stage reviewed; ladder/vault/platform helpers + SimLoop drive + drop-shoot gate + climbing replication + MapDef geometry + bot climb-seek & movement-drill exerciser + gate scripts. 245 unit tests green. |
| M4.5-P3 fleet 128-bot gate | claude | **done** | PASS on `game2` (server pinned to P-cores 0-3): `winner=1 elapsed=317s peak tick=23.46ms (<33.3)`; `climbs=9 vaults=16` (both ≥1), agg 18.7 Mbit/s, `dropblk=5`. ≤48 smoke also PASS (`climbs=4 vaults=7`). Evidence `docker/srvlog-20260616-115725.log`. |

## M5 Phase 1 (Land Vehicles + Substrate) — CLOSED ✅ (2026-06-16)

Spec: [`docs/specs/vehicles.md`](specs/vehicles.md). Plan: [`docs/plans/m5-p1-vehicles.md`](plans/m5-p1-vehicles.md) — 18 TDD tasks (substrate → land transport → gate). Built on the `m5-p1-vehicles` branch via `subagent-driven-development` (heavy server-integration tasks T10/T11/T12/T16 read-only spec-reviewed; HEAD verified after each). Vehicles multiplex into the existing `SNAPSHOT` (disjoint ID range, radius relevance + delta history); custom-kinematic physics in `shared/sim/` (M7-prediction-ready). Milestone: `docs/milestones/M5-vehicles.md`.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M5-P1 spec + plan | claude | done | `docs/specs/vehicles.md`, `docs/plans/m5-p1-vehicles.md` (18 tasks) |
| M5-P1 execute (18 tasks) | claude | **done** | subagent-driven; T10/11/12/16 reviewed. Catalog/State/Vehicle+physics, World/SimLoop slaving, SNAPSHOT codec, protocol, InputValidate, map spawns, enter/exit, replication, HP/blast/destruction+respawn, repair kit, mounted gun, bot crew, telemetry. |
| M5-P1 deterministic combat test | claude | **done** | `tests/vehicle_gate_test.gd` — RPG→HP→destruction + repair-restores-HP proven deterministically (authoritative; AGENTS.md §10). 309 unit tests green. |
| M5-P1 BattleBit balance | claude | **done** | transport 600 HP, RPG 800 anti-vehicle @150 m/s × 3 reserve, repair 6/tick (AGENTS.md §9). Found+fixed real bugs en route: `drive_toward` never steered; RPG launched at grenade speed (18 m/s); 1-RPG reserve. |
| M5-P1 fleet 128-bot gate | claude | **done** | PASS on `game2` (P-cores 0-3): `winner=0 elapsed=272s cap_events=4 peak tick=23.67ms (<33.3) agg=17.8 Mbit/s enters=6 transport_m=930.8`; combat counters reported (emergent `veh_dead=1 rkt_veh=1` this run). Bot vehicle tactical AI deferred to M7 client pass. Evidence `docker/srvlog-20260616-210141.log`. ≤48 CI smoke also PASS. |

## Active tasks (M0) — complete ✅

| Task | Owner | Status | Notes |
|---|---|---|---|
| Repo scaffold + git init | claude | done | |
| Docs system (README/AGENTS/TASKS/milestones) | claude | done | |
| ADR-0001 core language, ADR-0002 project structure | claude | done | |
| Scaffold Godot projects wired to `shared/` | claude | done | single project, 3 roles |
| M0 connect gate + smoke test | claude | done | `ci/connect_smoke_test.sh` PASS |

## Next up (M1) — write specs before coding

| Task | Owner | Status | Notes |
|---|---|---|---|
| `docs/specs/wire-protocol.md` | — | todo | brainstorm first |
| `docs/specs/netcode-replication.md` | — | todo | tick, snapshots, prediction/reconciliation |
| `docs/specs/interest-management.md` | — | todo | spatial grid / AoI — critical for 128p |
| Implement authoritative SimLoop + snapshots | — | todo | blocked by specs |
| Telemetry counters (tick time, bw/player) | — | todo | needed to measure the M1 gate |

Add new tasks here as they're discovered; promote per-milestone detail into the relevant `milestones/MX-*.md` file.
