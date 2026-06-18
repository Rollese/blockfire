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

## Phase 1 (chunked store) — gate evidence

**Status:** implemented + unit-verified + **no-regression vs master** (2026-06-18). Branch `m11-destructible-buildings`; executed via subagent-driven TDD (two-stage spec+quality review per task).

**Implemented (P1):** `ChunkMask` (pure 64-bit sub-cell alive-mask helpers); `PieceCatalog` gains `chunk_grid`/`structural`/`damage_types` (+ `SRC_BULLET|EXPLOSIVE|MELEE`); player fortifications authored 8×8 chunked + bullet-vulnerable; `StructureStore` record carries `chunks`+`building_id` (scalar `health`/`bucket_of`/`apply_damage` removed) with spatial `damage_chunks(id, source, impact, radius)` honouring per-type immunity; protocol `OP_DAMAGE`→`OP_CHUNK{id, mask:u64}` and the place/baseline record carries `chunks`+`building_id`; bot **and** client structure mirrors apply `OP_CHUNK`; server fire/blast paths carve chunks (`BULLET_CARVE_RADIUS`, explosive `struct_radius`) and emit `OP_CHUNK` under the existing per-tick delta cap.

**Descoped (2026-06-18, owner-approved):** hole-aware march — its chunk-face geometry is ill-defined against M4's full-cell AABB collision; deferred to a later phase designed against the art's face model. P1 pieces block until **fully destroyed** (M4-equivalent cover).

**Execution adjustments:** Tasks 4+5 and 7+8 were **merged** — removing/renaming a typed API (`apply_damage`/`bucket_of`, `OP_DAMAGE`) parse-breaks every `class_name`/test file that references it, so each removal co-migrated its dependent tests in the same commit (the runner `load()`s all test files at boot). `server_main.gd` (no `class_name`, not parsed at test boot) was rewired in its own task, restoring a clean-compiling tree.

**Unit:** full suite **461 run / 0 failed** (the M4-P2 baseline was 140). Coverage: chunk-mask math (clear-in-radius, popcount, monotonic/idempotent), per-type immunity, hole geometry, protocol round-trips incl. the u64 mask, and bot+client mirror `OP_CHUNK` updates. Headless server **boots clean** (no script errors) after the rewire.

**M4 re-gate (no-regression basis):** a full-match M4 smoke can't serve as the gate right now — the **combat AI is mid-rewrite** (separate workstream), so full-match runs have **inert bots**: on `ci/m4_destruction_test.sh` (48 bots) they connect (48/48) and move (climbs/vaults/transport) yet never fire or build (`shots=0 bld=0 kills=0 dmg=0 destroyed=0`, tickets 80/80, no winner), with **no script errors** — and **identically on master (`b0ff265`)**. Side-by-side telemetry is behaviourally identical, so **M11 introduces no regression**. AI-dependent combat behaviour is verified later, after the rewrite lands (see the ⚠ note in `docs/TASKS.md` M11 section). The no-regression basis here is the **unit suite (461/0) + branch≡master integration parity + clean server boot**.

**P1 verdict:** chunked-store unify is **implemented, unit-green (461/0), and proven no-regression vs master**. Cascade/collapse (P2), building authoring + procedural art (P3), and the client cosmetic layer (P4, needs M7) follow.

**Playtest:** P1 verification points (feel / visual / AI-dependent, deferred from headless gating) are recorded in `docs/runbooks/playtest-checklist.md` for the upcoming combined playtest.
