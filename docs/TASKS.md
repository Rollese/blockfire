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
| M5 | [Vehicles — Land](milestones/M5-vehicles.md) | **done ✅ (Land)** | **Land Vehicles + Substrate CLOSED 2026-06-16** — fleet gate PASS on `game2` (`peak tick=23.67ms<33.3`, transport_m=930.8, enters=6; combat chain proven deterministically in `tests/vehicle_gate_test.gd`), `docker/srvlog-20260616-210141.log`. 309 unit tests green. **Air vehicles deferred → M10** (last; need the rendered client to tune flight/balance — owner-directed 2026-06-16). |
| M5.5 | [Combat Depth II (ballistics/loadout/suppression/melee/throwables)](milestones/M5.5-combat-depth-2.md) | todo | Per-phase 128-bot gates: P1 projectiles hold tick+bw budget under full-auto; P2 armor TTK + suppression delta; P3 melee/back-stab/sledge/flash/impact. Mechanics proven deterministically; Conquest still reaches a winner. **Ballistics (P1) feeds M7-C2 prediction now** (owner-directed 2026-06-17). |
| M7 | [Art pass + UX polish — rendered client](milestones/M7-art-ux.md) | **in-progress** | First human-playable rendered client. **Re-scoped 2026-06-16:** P1 playable client + HUD (prediction/render + BattleBit HUD, placeholder art) → P2 art kit + LOD. **Steam/VAC + anti-cheat L3 deferred** to a later online/anti-cheat track (may stay a LAN game). Gate: end-to-end human playtest of a full Conquest match. Branch `m7-rendered-client`. **Pulled before M6** — M6 voice needs human testers in a live match (i.e. this client), and the deferred air vehicles (M10) need it to tune by feel. |
| M6 | [Voice (proximity + squad)](milestones/M6-voice.md) | todo | **Blocked by M7 client** (gate is human-validated in a live match). Voice works for human testers without breaking tick budget. |
| M7.5 | [Bot intelligence (tactical AI)](milestones/M7.5-bot-intelligence.md) | todo | Tactical, human-like, fair-play infantry bots (cover/stance, revive/resupply, attack/defend roles, grenades-vs-cover) usable as 128-player match-fillers; admin free-fly spectator + bot-AI debug overlay; bot-driver CPU scales to 128; Conquest reaches a winner; operator visual sign-off. |
| M8 | [Hardening & ops](milestones/M8-hardening-ops.md) | todo | Documented one-command stress run spins server + 128 bots in Docker. |
| M9 | [Online services (accounts, anti-cheat detection, matchmaking)](milestones/M9-online-services.md) | todo | Steam auth → skill-tier placement → matched into an official 128-slot server (with dynamic tier-merge); signed match reports update rating; a seeded cheat trace is flagged. |

| M10 | [Air vehicles (final content pass)](milestones/M10-air-vehicles.md) | **deferred (last)** | Was M5-P2. Helicopter/jet on the M5 vehicle substrate. **Blocked until the M7 rendered client** — flight feel + heli/jet balance must be tuned visually by playtest, not blind off telemetry (owner-directed 2026-06-16; see AGENTS.md §10). |

> Milestones are **sequenced and gated**. Do not start a milestone before the previous gate passes. M4–M6 may be reordered but each remains independently gated. **As of 2026-06-16: the rendered client (M7) is pulled before M6** (voice's gate needs human testers in a live match → needs the client), and **air vehicles are deferred to M10 (last)** — they need the client to balance by feel.
>
> **As of 2026-06-17: M5.5 (Combat Depth II) added** from the BattleBit feature-gap review. It is sim-layer and bot-gated like M4.5, but its **ballistics model is an input to the in-flight M7-C2** (bullet drop changes client prediction — decided now so M7 builds projectile-aware, not hit-scan). The remaining M5.5 phases follow the M4.5→M7 pattern (prove mechanics + budget headlessly; tune feel on the visual client). Two accepted gap-review items are presentation and live in **M7** instead: the **death-recap card (M7-P1)** and **audio (M7-P2)**.

## M5.5 — Combat Depth II — todo (planned 2026-06-17)

Spec: [`docs/specs/combat-depth-2.md`](specs/combat-depth-2.md). Milestone: [`M5.5-combat-depth-2.md`](milestones/M5.5-combat-depth-2.md). From the 2026-06-17 BattleBit feature-gap review (owner-approved). Three independently-gated phases; per-phase plans via `writing-plans` → `subagent-driven-development`.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M5.5 brainstorm + spec | claude | done | `docs/specs/combat-depth-2.md` (this brainstorm-of-record) |
| M5.5 P1/P2/P3 implementation plans | claude | done | [`p1-ballistics`](plans/2026-06-17-m5.5-p1-ballistics.md), [`p2-survivability`](plans/2026-06-17-m5.5-p2-survivability.md), [`p3-melee-throwables`](plans/2026-06-17-m5.5-p3-melee-throwables.md) |
| Hand ballistics model to **M7-C3** | — | todo | C2 done; M7-C3 (combat-depth UI) must build projectile-aware prediction (cosmetic tracer; server-confirmed hits), not hit-scan. See spec §1 + M7 ⚡ callout. |
| M5.5-P1 execute (ballistics, fire-mode, secondary) | — | todo | branch `m5.5-p1-ballistics`; subagent-driven; gate = tick+bw budget under full-auto at 128p. **Task 3 two-stage review** (fire path) |
| M5.5-P2 execute (armor class, suppression) | — | todo | branch `m5.5-p2-survivability`; depends on P1 projectiles (near-miss → suppression) |
| M5.5-P3 execute (melee/sledge, flashbang/impact) | — | todo | branch `m5.5-p3-melee-throwables`; reuses M4 grenade + structure-damage paths |

## M7 Phase 2 (Audio) — engine merged ✅; integration deferred

Spec: [`docs/specs/audio.md`](specs/audio.md). Plan: [`docs/plans/2026-06-17-m7-p2-audio.md`](plans/2026-06-17-m7-p2-audio.md). Built **in parallel with M7-C3 (combat-depth UI)** and **M7-P2 art**; all engine code lives in a fresh `client/audio/*` namespace + `data/sounds.json` so it could not conflict. **Merged to master 2026-06-17** (tip `0429958`, pushed to origin); full suite **451 run / 0 failed**. The engine is **dormant** — present on master but not yet wired into the client (see the deferred integration row).

| Task | Owner | Status | Notes |
|---|---|---|---|
| M7-P2 audio spec | claude (audio) | done | `docs/specs/audio.md` — was reserved per M7-art-ux.md; sound taxonomy, bus layout, distance attenuation + occlusion, voice-stealing/priority for 128p, signal-sourced events (view-only, AGENTS.md §7). |
| M7-P2 audio plan | claude (audio) | done | `docs/plans/2026-06-17-m7-p2-audio.md` — TDD task breakdown; final task is the **deferred** `client_main.gd` + `project.godot` integration. |
| M7-P2 audio engine (non-deferred) | claude (audio) | **done ✅** | **Merged to master 2026-06-17** (`0429958`). Self-contained `client/audio/audio_director.gd` (standalone Node, signal/method-driven, **not** wired into `client_main`) + pure helpers (attenuation/occlusion/voice-stealing/bus math) + `data/sounds.json` catalog. 27 headless unit tests; full suite 451/0 on merged master. |
| M7-P2 audio → client_main + project.godot wiring | — | **todo (next)** | Single integration task, now unblocked (C3 merged): wire `AudioDirector` into `client_main.gd`, declare `Master → SFX/UI/Listener` buses in `project.godot`, resolve catalog `stream` ids to real audio assets. Then owner playtest (feel/mixing is the gate, AGENTS.md §10). Open questions: `audio.md` §10 (all have working defaults). |

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

## M7 — Rendered Client (Art + UX) — in-progress

Specs: [`client-prediction.md`](specs/client-prediction.md), [`hud-ui.md`](specs/hud-ui.md), [ADR-0005 renderer](adr/0005-client-renderer.md). Milestone: [`M7-art-ux.md`](milestones/M7-art-ux.md). Branch `m7-rendered-client`. Re-scoped to **P1 (playable client + HUD) → P2 (art kit + LOD)**; Steam/VAC + L3 deferred to a later online/anti-cheat track.

| Task | Owner | Status | Notes |
|---|---|---|---|
| M7 brainstorm + re-scope | claude | done | 2026-06-16; Steam + L3 deferred; phased P1→P2 (owner-approved) |
| M7-P1 specs (client-prediction, hud-ui) + ADR-0005 | claude | done | committed on `m7-rendered-client` |
| M7-P1 C1 plan + execute (core infantry loop) | claude | done | `docs/plans/2026-06-16-m7-p1-c1-infantry-client.md`; impl complete + headless-validated (milestone doc) |
| M7-P1 C2 execute (vehicles, predicted + rendered) | claude | done | landed on `m7-rendered-client` (input redundancy + FIFO jitter-buffer); see git `m7-c2` |
| M7-P1 C3 plan (combat-depth UI) | claude | done | `docs/plans/2026-06-17-m7-p1-c3-combat-depth-ui.md` — squad/scoreboard, DBNO/revive, gadget/grenade, build/destroy feedback, deploy-on-squadmate, death-recap (`ROSTER`/`SET_SQUAD`/`DEATH_INFO` + extended `SELF_STATE`/`DeploySpawn`) |
| M7-P1 C3 execute (combat-depth UI) | claude | **done ✅** | **Owner-validated 2026-06-17 (tip `dc3479c`).** 22-task plan + a long owner-playtest fix loop. Full suite green (400 run / 0 failed); ≤48 smoke PASS (winner=0, peak 15.76ms<33.3); Tasks 13 & 15 two-stage read-only reviewed (SPEC-COMPLIANT + APPROVE). Owner ran the full loop on desktop→game2: squad/scoreboard, DBNO/revive (teammate-only, "being revived" cue), death-recap (correct killer/weapon/dist/HP + damage), respawn cooldown, deploy-on-teammate, prone toggle, throwable selector, build/destroy, squad menu (U), in-bounds. Playtest surfaced + fixed many pre-existing sim bugs (pawn/vehicle map-bound clamps, seat-vacate-on-death, downed-combat rules, deploy id/slot ref keying, RPG-loadout trap → humans never roll Engineer, recap attribution to the downer). Deferred (P2/separate vehicle pass): grenade explosion VFX, corpse-on-death, vehicle riding/exit/enter. |
| M7-P1 gate (full Conquest match, placeholder art, complete HUD) | — | todo | human playtest sign-off + server log |

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
