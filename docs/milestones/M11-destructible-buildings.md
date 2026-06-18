# M11 — Destructible Buildings

**Status:** todo (spec ratified 2026-06-18; not started) · **Blocked by:** M7 rendered client (cosmetic layer + feel gate) · **Coordinates with:** M5.5-P3 (melee sledge/pickaxe)

**Objective:** BattleBit-style destructible **map buildings** — almost all walls, interiors, and stairs can be destroyed, with chain-reacting structural collapse — on the existing M4 `BuildGrid`/`StructureStore`/`PieceCatalog` substrate, networked within the M4 event/interest/cap discipline.

## Why now (spec) / later (build)

Destruction + gunplay feel are the most important parts of the game (owner-directed 2026-06-18), so this gets a full milestone-grade design. The **sim** is provable deterministically and bot-gated; the **feel** (holes, brick debris, collapse cinematic) cannot be tuned blind — it needs the rendered client and a human playtest. So the spec is authored now and **implementation is sequenced after the M7 client lands** (same pattern as M5/M10 vehicles and M4.5→M7).

## Scope

- **Two granularities:** pieces (2 m cells; structure/support/collapse) + **0.25 m sub-cell chunks** (8×8 = 64-bit alive-mask per piece face; holes/chipping).
- **Unify** `StructureStore` so every piece is chunked; M4 player-building is refactored onto it and **re-gated** (no second destruction codepath).
- Cover: a piece blocks until **fully destroyed** (M4-equivalent). **Hole-aware march** (shoot through partial holes) is **deferred** to a later phase (needs the art's face geometry — amended 2026-06-18).
- **Support-reachability cascade**: destroying load-bearing pieces orphans unsupported pieces → removed (chain reaction); degrades to a single **whole-building collapse** event for large orphans (→ swap to static rubble).
- Damage from **explosives** (reuse M4 frag + M4.5 RPG) and **melee** (sledge/pickaxe). **Bullets do not** carve building walls (per-type catalog flag; player-built fortifications keep M4 bullet vulnerability).
- **Fully procedural** building art kit (walls/window/door/floor/stair/column/railing + props) with whole→damaged→destroyed states + per-building rubble model; furniture/props are non-structural destructible cover pieces.
- **Client cosmetic layer** (M7-era, never networked): solid-until-damaged LOD, MultiMesh hole rendering, GPU-particle brick debris, masked collapse cinematic (shake/rumble/smoke/sink → rubble swap).

## Gate (split)

- **Gate A — sim (128-bot headless):** a Conquest match on a map with destructible buildings holds tick < 33.3 ms + bandwidth budget; chunks destroyed (holes), pieces removed, a cascade fires, ≥1 building collapses, destruction replicates to bots, and the M3 Conquest loop still reaches a winner. **Plus a full M4 re-gate** (player building/destruction unchanged after the unify refactor).
- **Gate B — feel (owner playtest):** holes/debris/collapse cinematic validated on the rendered client (AGENTS.md §10).

## Risk note

Highest netcode/physics-cost feature class (same family as M4). The tick is snapshot-dominated and rides ~29–32 ms against 33.3 ms at 128 bots, so M11 must add **no systematic per-tick cost**: chunk damage + cascade are **event-driven** (rare vs 30 Hz), replication reuses the M4 `MAX_STRUCTURE_DELTAS_PER_TICK` cap + carry, collapse is **one** event, and the only steady-state addition is a single bit test in the ray-march hit. The unify refactor touches M4's closed hot paths — the M4 re-gate is mandatory. Profile `fire`/`snap`/cascade `[perf]` on the fleet early.

## Specs required

- `docs/specs/destructible-buildings.md` (brainstorm-of-record, ratified 2026-06-18).
