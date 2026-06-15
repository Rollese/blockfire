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
| M4.5 | [Combat depth & class identity](milestones/M4.5-combat-depth.md) | todo | DBNO/revive/bandages, body dragging, ladders, vaulting, drop-shoot prevention, class gadgets (C4/mines/ammo bags/RPG/medic bag), weapon attachments, bullet penetration. All features active in 128-bot match; tick + bw budget held; Conquest winner reached. |
| M5 | [Vehicles (land + air)](milestones/M5-vehicles.md) | todo | Vehicles usable under load; bots can occupy/transport. Requires RPG (M4.5) for anti-vehicle play; Engineer repair kit defined in M4.5, wired to vehicle HP here. |
| M6 | [Voice (proximity + squad)](milestones/M6-voice.md) | todo | Voice works for human testers in a live match without breaking tick budget. |
| M7 | [Art pass + UX polish](milestones/M7-art-ux.md) | todo | End-to-end human playtest of a full Conquest match. |
| M8 | [Hardening & ops](milestones/M8-hardening-ops.md) | todo | Documented one-command stress run spins server + 128 bots in Docker. |
| M9 | [Online services (accounts, anti-cheat detection, matchmaking)](milestones/M9-online-services.md) | todo | Steam auth → skill-tier placement → matched into an official 128-slot server (with dynamic tier-merge); signed match reports update rating; a seeded cheat trace is flagged. |

> Milestones are **sequenced and gated**. Do not start a milestone before the previous gate passes. M4–M6 may be reordered but each remains independently gated.

## Active work — M4.5 Phase 1 (Survivability)

Spec: [`docs/specs/combat-depth.md`](specs/combat-depth.md) (three-phase split). Plan: [`docs/plans/2026-06-15-m4.5-p1-survivability.md`](plans/2026-06-15-m4.5-p1-survivability.md) — 9 TDD tasks (DBNO/revive/bandages). Branch `m4.5-combat-depth`. Execute via `subagent-driven-development`; P2 (gadgets/RPG/penetration/attachments) and P3 (movement) get their own plans next.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M4.5-P1 brainstorm + spec | claude | done | `docs/specs/combat-depth.md` committed |
| M4.5-P1 implementation plan | claude | done | `docs/plans/2026-06-15-m4.5-p1-survivability.md` |
| M4.5-P1 execute (9 tasks) | — | todo | subagent-driven; Tasks 5 & 7 get a review subagent |
| M4.5-P1 fleet 128-bot gate | — | todo | unraid SENET; assert `downed≥1 revives≥1`, winner, peak tick <33.3ms |

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
