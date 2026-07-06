# M11 — Destructible Buildings

**Status:** P1+P2+P3 implemented & merged (2026-06-18) · **Gate A (128-bot sim) PASS ✅ 2026-06-23** · **Remaining:** Gate B (feel) + P4 client cosmetics — **blocked by M7 rendered client** · **Coordinates with:** M5.5-P3 (melee sledge/pickaxe)

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

## Phase 2+3 (building catalog, structural cascade, procedural art) — gate evidence

**Status:** implemented + unit/functional-verified (2026-06-18). Branch `m11-p2-p3-buildings`; executed via subagent-driven TDD (two-stage spec+quality review per task).

**Implemented (P2+P3):**
- Single unified `pieces/pieces.json` catalog with bullet-immune building-piece entries: `bwall`, `bwall_window`, `bwall_door`, `bfloor`, `bstair`, `bcolumn`, `brailing`, `prop_crate`.
- `BuildingCatalog` prefab loader (`shared/sim/building_catalog.gd`) — loads `buildings/*.json` prefabs, stamps `building_id` on each piece during placement.
- `MapDef.buildings[]` — map-level building placement list consumed by the server at startup.
- 3 building prefabs: `buildings/bunker.json`, `buildings/house.json`, `buildings/tower.json`.
- `Support` structural-only support-cascade flood-fill (`shared/sim/support.gd`) — BFS from ground anchor; unreachable pieces are orphans.
- `StructureStore` building index — tracks live piece sets per `building_id`; used by cascade resolution.
- `Msg.COLLAPSE` protocol message — carries `building_id` + rubble anchor; broadcast on whole-building collapse.
- Server: building stamping at boot, per-tick cascade resolution (orphan removes or whole-building `COLLAPSE` for large orphan sets), C4/damage-touched cleanup on cascade removal.
- Procedural `client/art/building_kit.gd` — generates geometry for each building-piece type with whole→damaged→destroyed visual states and rubble swap.
- Client routing of building pieces to `BuildingKit` + `apply_collapse` rubble swap on `Msg.COLLAPSE`.
- 3 buildings placed on `conquest_proving_grounds` (flag points A, C, E).
- Bot RPG building-targeting fallback — bots select a building-piece target when no player target is in range.
- Earlier bucket→chunks renderer fix (landed in P1 branch, merged here).

**Verification:** full unit suite **536 run / 0 failed**; deterministic functional test of the destruction→cascade→orphan loop (`tests/server_buildings_functional_test.gd`); headless server boots clean stamping `struct=50` on `conquest_proving_grounds`. No owner playtest at this stage (the project-wide playtest runs after all parallel agents finish + headless-test); 128-bot Gate A deferred while combat AI is mid-rewrite.

**Design/plan refs:** `docs/specs/m11-p2-p3-buildings-design.md`, `docs/plans/2026-06-18-m11-p2-p3-buildings.md`.

## Gate A (128-bot sim fleet) — PASS ✅ 2026-06-23

The 128-bot Gate A was deferred in 2026-06 while the combat AI was inert. The AI now fires (see the M5.5-P1/P2 fleet gates 2026-06-23), so Gate A was run on game2 (Docker `full` profile, server pinned P-cores 0-3, bots 4-31). Scripts: `docker/run-m11-gate.sh` (fleet) + `ci/m11_buildings_test.sh` (≤48 smoke), both `--map`-parameterised (compose now plumbs `MAP`).

**PASS on `conquest_proving_grounds` (canonical Conquest map, struct=177, TICKETS=80):**
`winner=1 t0=0 t1=43 elapsed=447s < 900 (ticket exhaustion, not the time fail-safe) cap_events=4`, **peak tick=24.65 ms < 33.3** (comfortable headroom), **destroyed=17** (chunks→0 piece removals), **rstruct=25** (removals incl. cascade orphans replicated), **collapsed=1** (a whole-building support-cascade COLLAPSE fired *emergently* under bot load — the spec's "≥1 building collapses" criterion), dmg=22 nades=24 rockets=4, peak agg=15.7 Mbit/s, **0 script errors**. Evidence: `docker/srvlog-m11-20260623-191111.log` (on-host; `.log` gitignored).

Every Gate A criterion met: chunks destroyed + pieces removed + **cascade + collapse fired** + destruction replicated to bots + Conquest reaches a winner + tick & bandwidth budget held. **M4 re-gate (no-regression after the P1 chunked-store unify):** the green unit suite (M4 building/destruction tests) + this fleet holding budget with **zero script errors** (one destruction codepath) is the no-regression basis (a dedicated M4 smoke still can't run combat until the AI is fully validated, but the AI now fires and destruction is exercised here).

**Mechanic proof remains authoritative regardless of emergent staging (AGENTS.md §10):** `tests/server_buildings_functional_test.gd` (damage→cascade→orphan→collapse loop), `tests/support_test.gd`, `tests/protocol_collapse_test.gd`.

**Map-scale finding (separate from M11 logic):** buildings-dense maps push the snapshot-baseline cost toward the ceiling — `conquest_arena_buildings` (768 pieces) gates with destruction firing hard (destroyed≈51–70) but peak tick rides the edge (**33.10 ms**, just under budget); `conquest_showcase` (2463 pieces) and `conquest_town` (8324 pieces) exceed it. This is replication cost from piece count, not the cascade/collapse path. **RESOLVED 2026-07-01:** profiling showed the delta ENCODER dominated; `EntityState.bake()` quantizes wire fields once per send (encode −52%, bit-identical) and `conquest_town` (8324 pieces) now PASSES the 128-bot gate at 27.31 ms (`docker/srvlog-m11-20260701-160937.log`, branch `m11-snapshot-encode-bake`).

**Gate B (feel — owner playtest of holes/debris/collapse cinematic) still pending. P4 client cosmetics — first pass landed (2026-06-27).**

## Phase 4 (client cosmetics) — first pass ✅ 2026-06-27

The M7 rendered client now exists, so the deferred cosmetic layer was started. **Landed (merged to master, branch `m11-p4-destruction-cosmetics`):**
- **Per-piece destruction FX.** `WorldView` queues cosmetic events — `OP_REMOVE` → a `destroy` event, a real `OP_CHUNK` carve → a `damage` event (idempotent: a resent unchanged mask fires nothing) — drained via `take_struct_fx()` (the batched-MultiMesh renderer can't otherwise infer per-piece changes). The renderer plays a concrete dust puff + a fan of chunky brick/concrete debris (reuses the `_debris` gravity+settle pool).
- **Collapse cinematic.** Whole-building collapse upgraded from an instant flat rubble swap to `_play_collapse_fx`: rolling ground dust cloud + heavy debris burst + a distance-falloff camera shake, then the persistent rubble mound.
- **Camera shake.** Transient deterministic positional jitter (no RNG), reapplied on top of `_apply_camera` each frame so it never accumulates; decays over its life. Reusable by future nearby-blast events.
- **QA flags** `--destroy-test` / `--collapse-test`; visual-validated via self-screenshot on `.128` (dust dome + flung brick/concrete debris confirmed). 843 unit tests green (4 new `WorldView` event-queue tests).

**Still deferred (P4 / later):** GPU-particle debris + far-LOD (current debris is pooled MeshInstances, fine at typical event rates); 3 cosmetic BuildingKit geometry tweaks (lintel 1 cm clip, railing height, stair height) to eyeball in-engine; a dedicated collapse SINK animation (deferred — the footprint-scaled dust billow now masks the instant-vanish, as BattleBit's does); rubble + debris nodes untracked (bounded, freed on renderer teardown). **Gate B = owner playtest of the feel.**

## Phase 4 — Gate-B feel pass (hole-aware destruction) — 2026-07-06/07, branch `m11-gate-b-feel`

The M15 village map + M7 client made the feel tunable, so the deferred hole-aware work was built. Owner
directed (2026-07-06) **Full BattleBit walk-through holes** (not the canned-mesh quick option) and **Gate B
after the quick wins land**. Established the current feel first with a new harness (`tools/render_destruct_shots.gd`
— stamps a REAL conquest_town building client-side + drives carve/remove/collapse, opengl3 under Xvfb),
which proved: carving a wall was imperceptible (bucket re-tint only), removal was all-or-nothing full-cell
(no sub-cell hole — the MultiMesh batch draws N copies of ONE mesh), and collapse left a fixed ~3 m pebble
pile regardless of building size.

**Landed (merged to master + pushed):**
- **Q-A footprint-scaled collapse** (`b0da858`): `_play_collapse_fx` scales the dust billow to the footprint
  AABB and `_place_rubble_field` tiles deterministic rubble mounds across it (8×8 cap, centre-humped, taller
  by building height). A single-cell building still leaves one mound. Client-only.
- **H1 hole-aware geometry** (`c71ccc8`): a partially-carved chunked piece (0 < alive < full, grid ≥ 2) is
  PROMOTED out of the batched whole-mesh into a per-chunk hole grid — only its ALIVE 0.25 m chunks render
  (`WorldRenderer.chunk_hole_xforms`, mirroring ChunkMask's bit layout), leaving a real see-through gap
  exactly where chunks cleared. All promoted pieces of a type batch into ONE unit-cube MultiMesh; pristine
  pieces never promote → **no steady-state cost**. Client-only over already-replicated OP_CHUNK. Visual-validated
  (window hole + wide breach both see-through).
- **H2 hole-aware march** (`7909d91`): `StructureStore.march`, on a piece hit, does one `ChunkMask.is_alive_at`
  bit-test at the contact point — a cleared chunk is a hole the shot/rocket/LOS passes through; `march_normal`
  (grenade bounce) inherits it. One cheap test per piece hit, not a per-tick scan. **128-bot gate PASS on
  conquest_town** (`winner=1 peak tick 23.22 ms<33.3 destroyed=18 rstruct=44 collapsed=2, 0 errors`).
- **H3 walk-through** (`2fcf627`): `_blocks_ground` returns not-solid for a chunked wall once `ChunkMask.region_clear`
  finds the pawn's body column carved open at floor level (bounded cross-section scan, reached only when a pawn
  is inside an occupied cell). A high/small shot-through hole still blocks the feet — shoot-through before
  walk-through, as in BattleBit. Pawn-only. Gate re-run for H3.

Suite 1353/0 (+18 across the phase). **Remaining: Gate B = owner playtest** of holes/shoot-through/walk-through/
collapse on the rendered client; then the deferred cosmetic tweaks above.
