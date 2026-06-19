# Spec — M14: Walkable Multi-Floor Structures (Structure Verticality)

**Status:** brainstorm-of-record, ratified 2026-06-19. **Phase 1 of the building program** (precedes
the new building set; the finer sub-cell grid is a later milestone). **Builds on:** M4.5-P3
(ladders/platforms/vault) + M11 (StructureStore / building pieces). **Branch:** `m14-walkable-multifloor`.

## Objective

Let pawns **walk into, stand on, and climb between the floors of a destructible structure** — so the
M11 buildings (and the upcoming warehouse / two-story house / supermarket) are real interior/vertical
spaces, not solid shells. Today structure pieces only *block* horizontally at ground level; map
`platforms`/`ladders` are the only standable-at-height surfaces. This milestone makes structure
**floors standable**, **walls block per-floor**, **stairs walkable**, and adds **height-based fall
damage** — all server-authoritative, client-predicted, deterministic, with **no protocol change**.

## Background — the foundation we build on (M4.5-P3)

The vertical-movement machinery already exists and is proven (M4.5-P3 gate PASS):

- `shared/sim/ladder.gd` — `Ladder.platform_floor(platforms, x, z, y)` returns the highest platform
  top at/below `y` whose footprint contains `(x,z)`; `capture`/`should_engage`/`climb_step` drive
  ladder climbing.
- `shared/sim/sim_loop.gd` — `_apply_platform_floor(p)` snaps a pawn onto the highest surface
  at/below them and clears `grounded`; also runs ladder capture, vault, and structure
  `resolve_movement`/`march`. Geometry arrays (`ladders`, `platforms`) are server-set, empty during
  client prediction (the structure store, however, **is** mirrored on the client).
- `shared/sim/pawn.gd` — kinematic vertical physics already present: `grounded`, `velocity.y`,
  `GRAVITY`, `JUMP_V0`.
- `shared/sim/structure.gd` — `resolve_movement(from,to)` (horizontal block), `_blocks_ground(p)`
  (cell occupancy), `ground_blocker_top(p)` (piece top, used by vault), `march` (ray).

The gap: structure pieces don't feed `platform_floor`, `_blocks_ground` only checks the **ground**
cell `(x,0,z)`, and stairs are solid blockers. We close exactly those gaps.

## Design

All new logic lives in `shared/sim/` (shared by server + client prediction), is pure where possible
for unit-testing, and adds **no replicated fields** (pawn `y` is already in the snapshot; the
structure store is already mirrored; fall damage is an ordinary health change).

Conventions: `CELL_SIZE = 2.0 m` (`BuildGrid`). A piece at grid cell `Y` spans world `[Y·2, Y·2+2)`.

### 1. Standable structure floors

New `StructureStore.floor_height_at(x: float, z: float, y: float) -> float`: the highest **walkable
structure surface** at or below `y` at column `(x,z)`, or `-INF` if none.

- A `bfloor` (and any future floor-class piece) at cell `Y` yields a walkable surface at world height
  `Y · CELL_SIZE` — **the cell's base plane**. (Decision: the surface is the cell base, not the slab
  top, so floor heights are clean multiples of `CELL_SIZE`; the `bfloor` render mesh is aligned so its
  visible top sits at this plane — art offset adjusts to the sim, never the reverse.)
- A `bstair` cell contributes a **ramped** surface — see §3.
- Query is a small set of cell-hash lookups walking down from `cell_of(y)` to `0` at `(x,z)` (bounded
  by the building's height, a handful of cells), returning the first occupied floor/stair surface
  `≤ y + ANCHOR_EPS`. O(building height), not O(structures).

`SimLoop._apply_platform_floor(p)` folds this in: effective floor =
`max(0.0 /*ground*/, Ladder.platform_floor(platforms,…), structures.floor_height_at(p.x, p.z, p.y))`.
The pawn snaps to / gravity-settles onto the highest surface at or below them, exactly as platforms
work today. Step off an edge → the column's next-lower surface (or ground) is returned and the pawn
falls to it.

### 2. Height-aware horizontal collision

`_blocks_ground(p)` today checks `cell_of(p.x, 0.0, p.z)` — the ground row only, so upper-floor walls
never block. Change it to check the cell at the pawn's **feet height**:
`cell_of(p.x, p.y + FEET_EPS, p.z)` where `FEET_EPS` (~0.1 m) lifts the sample off the floor plane
into the wall's cell band. Result: a wall at cell `Y=1` blocks a pawn standing on the `Y=1` floor
(`p.y ≈ 2`), while the ground floor below (`p.y ≈ 0` → cell `Y=0`) is unobstructed by it.
`resolve_movement(from,to)` already receives the full `Vector3` (incl. `y`), so **no signature
change** — it just stops ignoring `y`. Door pass-through (`passable`, from the round-2 work) composes
unchanged.

### 3. Walkable-ramp stairs

A `bstair` at cell `Y` connects floor `Y` (low edge) to floor `Y+1` (high edge), rising `CELL_SIZE`
across the cell's run. A new pure helper `shared/sim/stairs.gd`:

- `Stairs.run_dir(yaw) -> Vector2` — the XZ ascent direction from the piece `yaw` (the stair's render
  rises toward `-Z` at yaw 0; map yaw→dir accordingly).
- `Stairs.surface_at(cell, yaw, x, z) -> float` — fractional progress `f ∈ [0,1]` of `(x,z)` along
  `run_dir` within the cell → surface `= Y·CELL_SIZE + f·CELL_SIZE`.

`floor_height_at` returns this ramped height for a stair cell. A stair cell is **non-blocking
horizontally** (you walk onto/up it, like a `passable` piece) but provides the rising floor, so a pawn
crossing it ascends smoothly. Placement rule (authoring): a stair at cell `Y` must sit adjacent to a
floor at `Y` (low) and `Y+1` (high) so both ends connect. (Ladders remain available via map geometry;
a `bladder` structure piece is **deferred** — stairs cover vertical traversal for v1.)

### 4. Height-based fall damage (BattleBit-style)

`Pawn` gains `fall_peak_y` (highest `y` reached since leaving the ground). While `not grounded`,
`fall_peak_y = max(fall_peak_y, y)`. On the tick `grounded` flips true, `fall = fall_peak_y - y`:

- `fall ≤ SAFE_FALL` (`= 4.0 m`): no damage.
- else `damage = round((fall - SAFE_FALL) · FALL_DMG_PER_M)`, `FALL_DMG_PER_M ≈ 13.5` → ~100 (lethal)
  at ≈ 11.4 m, clamped to `[0, current health]`.

Applied **server-side** (authoritative) in the movement/health step; deterministic from the pawn's `y`
trajectory, so the client predicts the same landing and the server-confirmed health reconciles
normally. Reset `fall_peak_y` to `y` on landing, deploy/respawn, ladder/vault engage, and while
grounded. Jumping (apex ~`JUMP` height) stays well under `SAFE_FALL`, so normal movement is unaffected.

### 5. Determinism, netcode & tick budget

- **No protocol change.** `pawn.y` is already replicated; the structure store is already mirrored on
  the client; fall damage is an ordinary `health` change.
- **Prediction parity:** all of the above is shared `sim/` code; client prediction runs it against the
  mirrored store → identical to the server. (Validated by a prediction-parity test, the M1/M2 pattern.)
- **Cost:** `floor_height_at` + height-aware `_blocks_ground` are O(building-height) cell-hash lookups
  per pawn/tick — comparable to the existing `platform_floor`/`resolve_movement` cost, no new per-tick
  scan over all structures. Re-profile `move`/`snap` on the 128-bot fleet; the budget rides ~29-32 ms
  at 128 so this must add no systematic cost (it doesn't — event-free, bounded per pawn).

### 6. Bots (v1: ground-level)

Bots do **not** path between floors in v1 (humans-only verticality, per ratified decision). The
changes are ground-safe: ground-floor collision at `p.y ≈ 0` resolves to cell `Y=0` exactly as today,
so existing bot movement/fighting around and through ground floors is unchanged. Bots holding/clearing
upper floors is a later AI milestone.

### Out of scope for v1 (explicit)

- **Ceiling/headroom collision** — jumping up into an overhead floor does not bonk (you rise and fall
  back via gravity); no standing *inside* a floor. Polish, deferred.
- **Bot multi-floor pathing** — deferred (see §6).
- **Finer sub-cell grid** — the *next* building milestone; this spec stays on the 2 m grid.
- **`bladder` structure ladder piece** — deferred; stairs cover v1.
- **Sloped-roof walkability** — pitched roofs (in the piece-kit milestone) are not walkable surfaces
  in v1 (cosmetic + destructible only).

## Gate

Per project discipline (AGENTS.md §10 — prove mechanics deterministically, don't gate on emergent AI):

- **Deterministic mechanic tests (unit/integration):** pawn stands on a structure floor; ascends a
  stair ramp from floor `Y` to `Y+1`; a wall on the upper floor blocks while the same column on the
  ground floor does not; stepping off an upper-floor edge falls to the lower floor/ground; fall-damage
  curve (no damage ≤ 4 m, scaling above, lethal ~11-12 m); **client-prediction parity** with the server
  for a multi-floor traversal sequence.
- **128-bot fleet tick gate:** a Conquest match on a map with multi-floor buildings holds mean tick
  < 33.3 ms (bots ground-level) and still reaches a winner; `[perf]` `move`/`snap` show no regression.
- **Human playtest (feel):** walk in, climb stairs to an upper floor, fight from a window/upper floor,
  drop/fall off and take fall damage — reads right.

## Files (anticipated)

- `shared/sim/structure.gd` — `floor_height_at`; height-aware `_blocks_ground`/`resolve_movement`;
  stair-cell treated as non-blocking-but-ramped.
- `shared/sim/stairs.gd` — **new** pure ramp-height helper (`run_dir`, `surface_at`).
- `shared/sim/sim_loop.gd` — fold structure floor into `_apply_platform_floor`; stair ramp integration.
- `shared/sim/pawn.gd` — `fall_peak_y` tracking + fall-damage application (or a small `Fall` helper for
  the pure curve).
- `client/world_renderer.gd` / `client/art/building_kit.gd` — align the `bfloor` mesh top to the
  cell-base walkable plane (§1 convention).
- `tests/` — `stairs_test`, structure-floor standing, height-aware collision, fall-damage curve,
  multi-floor prediction-parity.

## Open decisions (resolved during brainstorm)

- Stairs = **walkable ramp** (not stepped, not ladder-only).
- Verticality = **humans only** in v1; bots ground-level; gate is deterministic tests + playtest.
- Fall damage = **yes, height-based** (`SAFE_FALL = 4 m`, lethal ~11-12 m).
- Floor surface = **cell base plane** (`Y·CELL_SIZE`); art aligns the slab mesh to it.
