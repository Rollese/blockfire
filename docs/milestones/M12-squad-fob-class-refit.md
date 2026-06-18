# M12 — Squad FOB & Class Refit (Recon removal, leader FOB spawn)

**Status:** todo · **Sequence:** near-term — **lands before/alongside the in-progress M7 client** (so M7 builds the right class-select + deploy/spawn UI) · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md) · **Spec:** [`squad-fob-class-refit`](../specs/squad-fob-class-refit.md)

> **Numbering vs sequence:** the milestone *number* is M12 (next free after the in-flight M11 destructible-buildings), but its *position in the build sequence is near-term* — it should land before the M7 client locks its class/spawn UI. Numbering ≠ strict order here (cf. M7 pulled before M6, M10 deferred last).

**Objective:** Apply the ADR-0007 §1+§2 design changes at the sim layer: remove the Recon class, make the DMR an Assault-only marksman option with no sniper rifles in the game, move the claymore to the Engineer, and replace M3's free squad spawn with a **squad-leader FOB** (squadmate-rally retained as a fallback). Server-authoritative, shared rules in `shared/sim/`, bot-fleet-gated + deterministically proven (the M3/M4.5 mould).

## Scope

- **Class refit** (`shared/sim/loadout.gd`): four classes (Assault/Medic/Engineer/Support); Recon removed from enum + class rolls.
- **DMR Assault-only** (`loadout.gd can_equip`): server-validated; no sniper weapon added (`AR/SMG/DMR/RPG` unchanged; DMR stays semi-auto).
- **Claymore → Engineer**: Gadget A becomes a deploy-screen pick-one (C4 *or* claymore); mine data/server tick unchanged from M4.5.
- **FOB** (`shared/sim/fob.gd` NEW + spawn path): leader-built, one per squad; spawning disabled while an enemy is within `FOB_VICINITY_RADIUS`; FOB persists (no proximity-destroy); replicated to own team.
- **Spawn selection** (`server/server_main.gd`): source set = home base + owned points + FOB (when enabled) + alive squadmate (fallback).
- **Protocol**: `Msg.PLACE_FOB` / `Msg.REMOVE_FOB` + FOB entity replication (sequenced after M11 merges — shared `protocol.gd`).
- **Bot AI** (`bots/bot_driver.gd`): 4-class rolls; Engineer rolls C4/claymore; leader bots place + use FOBs (scripted FOB drill if organic placement is match-outcome-dependent).

## Gate

A **128-bot Conquest match runs start → win** with the refit active:

- **No Recon** class present; DMR equips **only** on Assault (loadout-validation unit test rejects DMR on other classes); claymore selectable on Engineer.
- **FOB exercised**: FOBs placed (`fobs_placed ≥ 1`), used as a spawn source (`fob_spawns ≥ 1`), and **disabled by enemy proximity** at least once (`fob_disabled ≥ 1`) — telemetry counters.
- **Squadmate-rally fallback** still functions (unit-tested; observed when no FOB up).
- **Tick + bandwidth budget held** (mean tick < 33.3 ms at 128; no regression vs M3 `snap`).
- A **winner declared** via tickets (not the time fail-safe).

Mechanics also **proven deterministically** (unit/integration), per AGENTS.md §10: FOB placement validation, enemy-proximity enable/disable boundary, spawn-source selection, loadout restrictions — none gated on emergent bot AI.

## Specs

- [`docs/specs/squad-fob-class-refit.md`](../specs/squad-fob-class-refit.md) — brainstormed; design approved 2026-06-18.

## Supersedes / touches prior milestones

- **M3** "spawn on any alive squadmate" primary → superseded by the leader FOB (squadmate spawn demoted to fallback). M3 doc carries a superseded note → ADR-0007.
- **M4.5** Recon class + Recon-owned claymore → Recon removed; claymore reassigned to Engineer. M4.5 doc carries a superseded note → ADR-0007.

## Cross-milestone notes

- **M7 (client):** consumes this — build the 4-class select + FOB deploy/spawn UI. Land M12's sim change before M7 finalizes those screens.
- **M11 (destructible buildings, in-flight):** shares `shared/net/protocol.gd`; sequence the FOB message-id additions after M11 merges or coordinate with that agent.
