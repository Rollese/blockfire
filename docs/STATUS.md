# Blockfire — Current State (read this first)

**A LAN-playable Godot 4 BattleBit-clone: server-authoritative 128-player Conquest with client prediction, destructible buildings, heightmap terrain, and tactical bots.** This page is the fast orientation for a fresh agent. It is a *summary* — the authoritative board is [`TASKS.md`](TASKS.md); live design lives in [`specs/`](specs); what the code *actually does* is a `graphify query "…"` away (see [`AGENTS.md`](AGENTS.md) §1). Historical plans/sessions/reviews are in [`archive/`](archive) — **do not read those as current state.**

_Last refreshed: 2026-07-11 (documentation compaction). If this disagrees with `TASKS.md`, `TASKS.md` wins._

## Build priority (owner-directed, AGENTS.md §12)
**Infantry combat → real maps → destruction**, playtested, before anything else. **All vehicle work is deferred** to a post-core milestone (the M5 land-vehicle sim stays on master but gets no further investment; vehicle spawns are removed from shipping maps).

## Shipped & gated ✅ (on master)
- **Netcode core (M1)** — 128 pawns @ 30 Hz within tick/bandwidth budget; server-authoritative snapshot/delta.
- **Core FPS loop (M2)** — move + shoot + kills at 128 bots.
- **Conquest + respawn + squads (M3)** — full bot match start→win at 128.
- **Building + destruction (M4)** + **destructible buildings (M11)** — chunked `StructureStore`, support-cascade collapse, hole-aware walk-through destruction. Sim + feel built; **M11 Gate-B feel is in final owner playtest** (pending 2 new asset buildings).
- **Combat depth (M4.5)** — DBNO/revive/bandages, gadgets/RPG/penetration/attachments, ladders/vaulting.
- **Combat depth II (M5.5)** — stepped-projectile ballistics, fire-mode, armor classes, suppression, melee/back-stab/sledge, flashbang/impact grenades.
- **Land vehicles (M5)** — sim substrate, prediction-ready (further vehicle work deferred).
- **Rendered client (M7)** — human-playable; full HUD, prediction, victory/defeat screen. P1 gate **passed** by owner playtest.
- **Bot tactical AI (M7.5)** — perception/utility/humanize/behaviours engine (`bots/ai/*`); P2+P3 done, 128-bot gated. P4 squad-strategy + visual sign-off remain.
- **Hardening & ops (M8)** — one-command Docker stress run, telemetry schema, adaptive degradation, config + map rotation.
- **Walkable multi-floor (M14)** — stairs, per-floor walkability, fall damage (merged; re-confirm gates pending).
- **Heightmap terrain (M15)** — walkable hills/valleys, real cover, driveable, no wire change; playable village `conquest_town`.
- **Standing bleed + bandage (M16)** and **reserve-ammo economy (M17)** — BattleBit survivability + finite spare ammo.
- **Perf & netcode track** — native Rust snapshot encoder (ADR-0003 Phase A + A.5: `snap` ~24 ms→~2.8 ms on budget hardware), full 30 Hz snapshots, reliable BULK anti-HOL channel, adaptive tick-lead input clock. **Servers must `cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml` before fleet gates** (`ENCODER=gd` opts out).

## In flight 🚧 (active agents — coordinate, don't collide)
- **M19 — Class Select & Player Loadouts** — spec [`specs/class-select-loadout.md`](specs/class-select-loadout.md). P1a data model done; P1b wire/variant seam landing. Couples to the **weapon-variants registry**.
- **M20 — Stats & Analytics backend** — design [`superpowers/specs/2026-07-11-stats-analytics-backend-design.md`](superpowers/specs/2026-07-11-stats-analytics-backend-design.md). P1 ingest API + StatsReporter.

## Partial / blocked
- **M6 — Voice** — pure logic core + Opus GDExtension merged; relay-thread + client capture/playback wiring + live gate remain (needs the client).

## Deferred (do not start until the core is signed off)
- **M13 Assault mode** · **M18 Battle Royale** — planned, rules-variants over the shared sim (ADR-0009). Specs exist.
- **M9 Online services** · **M10 Air vehicles** — beta / post-1.0 (ADR-0007 §4). M10 is last (needs client to tune flight feel).

## Where things live
`AGENTS.md` working agreement · `TASKS.md` board (source of truth) · `milestones/` roadmap · `specs/` live design · `adr/` decisions · `runbooks/` ops · `gate-evidence/` gate logs · `archive/` history (not current). Code: `shared/` (rules run on both sides), `server/`, `client/`, `bots/`, `native/` (Rust), `tests/`.
