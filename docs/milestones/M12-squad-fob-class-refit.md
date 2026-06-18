# M12 — Squad FOB, Cooperative Construction & Class Refit

**Status:** todo · **Sequence:** near-term — **lands before/alongside the in-progress M7 client** (so M7 builds the right class-select, shovel/build, and deploy/spawn UI) · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md) · **Spec:** [`squad-fob-class-refit`](../specs/squad-fob-class-refit.md)

> **Numbering vs sequence:** the milestone *number* is M12 (next free after the in-flight M11 destructible-buildings), but its *position in the build sequence is near-term* — it should land before the M7 client locks its class/build/spawn UI. Numbering ≠ strict order here (cf. M7 pulled before M6, M10 deferred last).

**Objective:** Apply the ADR-0007 §1+§2 design changes at the sim layer: remove the Recon class (DMR Assault-only, no sniper rifles; claymore→Engineer); replace M4's instant placement with **universal shovel-based progressive construction** (small pieces solo-buildable, large structures + FOB need ≥2 squadmates shovelling together); and add a **squad-leader FOB** — a **cooperatively-built, destructible bunker** that becomes a squad forward-spawn (proximity-disabled while enemies are near, destroyed via M4 destruction, hunted by enemy AI), with squadmate-rally spawn kept as a fallback. Server-authoritative, shared rules in `shared/sim/`, bot-fleet-gated + deterministically proven (the M3/M4/M4.5 mould).

## Phases (each independently gated)

- **M12-P1 — Class refit.** 4 classes (Recon removed); DMR Assault-only; claymore→Engineer (pick-one vs C4). Self-contained, no new systems, **independent of M11** — lands first.
- **M12-P2 — Cooperative shovel construction.** Universal shovel (all classes); `BUILD_REQUEST` creates a *build site* that accrues progress as eligible builders shovel it; min-builders scale by size (small=1, large=2); completion → full M4 structure; shovel-repair (friendly); **enemy shovel-dismantle** of structures/sites (the no-explosives demolition route, ≪ explosive DPS); abandoned-site decay. **Supersedes M4 instant placement**; reuses M4 grid/catalog/collision + M4 destruction.
- **M12-P3 — Squad-leader FOB.** Leader places a FOB build site (one per squad); squad shovels it (≥2) into a high-HP bunker; becomes a spawn source gated by completion + enemy-proximity-disable + not-destroyed; spawn-selection integration; squadmate-rally fallback.

## Scope

- **Class refit** (`shared/sim/loadout.gd`, `weapon.gd`): 4 classes; DMR Assault-only (`can_equip`); no sniper weapon added (DMR stays semi-auto); Engineer Gadget A = C4 *or* claymore.
- **Shovel construction** (`shared/sim/build_site.gd` NEW, `structure.gd`/`piece_catalog.gd` ext): build sites with `build_progress`/`min_builders`; per-tick progress from eligible shovellers (interest-grid bounded); completion→structure; friendly repair; **enemy shovel-dismantle** (reduces site progress / structure HP via the M4 removal path); decay; catalog gains `build_cost`/`min_builders` + ≥1 large piece.
- **FOB** (`shared/sim/fob.gd` NEW + spawn path): leader-placed large build site → destructible bunker; one per squad; persists through leader death; proximity-disable; M4-destruction-removable.
- **Spawn selection** (`server/server_main.gd`): source set = home base + owned points + FOB (completed+enabled+alive) + alive squadmate (fallback).
- **Protocol** (`shared/net/protocol.gd`): `PLACE_FOB`/`REMOVE_FOB`; shovel-use input bit; `BUILD_REQUEST`→site; `STRUCTURE_DELTA` + `build_progress`/`under_construction`; FOB entity replication. **Sequenced after M11 merges** (shared structure store / protocol).
- **Bot AI** (`bots/bot_driver.gd`): 4-class rolls; shovel-build cover; **squad bots cooperatively build the FOB** (leader places, ≥2 shovel); enemy bots target/destroy enemy FOBs (**shovel-dismantle fallback when out of explosives**); scripted squad-build drill exerciser.

## Gate

Per phase, holding tick + bandwidth budget (mean tick < 33.3 ms at 128) and Conquest still reaching a winner; mechanics proven deterministically (AGENTS.md §10):

- **P1:** No Recon class present; DMR equips **only** on Assault (loadout-validation unit test rejects DMR elsewhere); claymore selectable on Engineer.
- **P2:** A **small** piece builds with **1** shoveller; a **large** piece advances **only with ≥2** simultaneous shovellers (telemetry: `built_small`, `built_large`, `build_blocked_solo`); shovel-repair restores HP; **enemy shovel-dismantle** removes an enemy structure (`dismantled ≥ 1`); budget held under 128-bot building load.
- **P3:** A squad **builds a FOB cooperatively** (`fobs_built ≥ 1`), **spawns on it** (`fob_spawns ≥ 1`), has it **proximity-disabled** by enemies (`fob_disabled ≥ 1`), and **destroyed** (`fobs_destroyed ≥ 1`) — all observed in a 128-bot match; squadmate-rally fallback still functions; a winner declared via tickets.

Deterministic proof (unit/integration), not gated on emergent AI: loadout restrictions; build-site progress + min-builders boundary; FOB placement validation, enemy-proximity enable/disable boundary, destroyed-FOB-not-a-spawn; spawn-source selection.

## Specs

- [`docs/specs/squad-fob-class-refit.md`](../specs/squad-fob-class-refit.md) — brainstormed; design approved 2026-06-18.

## Supersedes / touches prior milestones

- **M3** "spawn on any alive squadmate" primary → superseded by the leader FOB (squadmate spawn demoted to fallback). M3 doc carries a superseded note → ADR-0007.
- **M4 (Building)** instant placement → superseded by progressive shovel construction (build sites). **M4 destruction** + grid/catalog/replication are reused unchanged. M4 doc carries a superseded note → ADR-0007.
- **M4.5** Recon class + Recon-owned claymore → Recon removed; claymore reassigned to Engineer. M4.5 doc carries a superseded note → ADR-0007.

## Cross-milestone notes

- **M7 (client):** consumes this — build the 4-class select, the shovel/build UI + build-site ghost, and the FOB deploy/spawn UI + placeholder bunker model. Land M12's sim change before M7 finalizes those screens.
- **M11 (destructible buildings, in-flight):** shares `shared/net/protocol.gd` **and the structure store / `STRUCTURE_DELTA`**. M12-P2/P3 build on the same machinery — sequence them after M11 merges or coordinate with that agent. **M12-P1 (class refit) is independent of M11 and can land first.**
