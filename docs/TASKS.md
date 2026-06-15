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
| M4 | [Building & destruction](milestones/M4-building-destruction.md) | todo | Phase 1 (Building) gate PASS 2026-06-15 (laptop-48; fleet-128 pending) — Phase 2 (Destruction) next. Building/destruction under 128-bot load holds tick + bandwidth budget. |
| M5 | [Vehicles (land + air)](milestones/M5-vehicles.md) | todo | Vehicles usable under load; bots can occupy/transport. |
| M6 | [Voice (proximity + squad)](milestones/M6-voice.md) | todo | Voice works for human testers in a live match without breaking tick budget. |
| M7 | [Art pass + UX polish](milestones/M7-art-ux.md) | todo | End-to-end human playtest of a full Conquest match. |
| M8 | [Hardening & ops](milestones/M8-hardening-ops.md) | todo | Documented one-command stress run spins server + 128 bots in Docker. |

> Milestones are **sequenced and gated**. Do not start a milestone before the previous gate passes. M4–M6 may be reordered but each remains independently gated.

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
