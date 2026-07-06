# Spec — M15: Heightmap Terrain

**Status:** IMPLEMENTED 2026-07-06 (branch `m15-heightmap-terrain`) — deterministic suite (1326/0) + 128-bot fleet gate PASS on `conquest_proving_grounds` (`winner=1 elapsed=249s peak tick=16.72ms<33.3`); owner feel-playtest pending. Ratified 2026-07-03. See `docs/sessions/2026-07-06-m15-heightmap-terrain.md`.
**Builds on:** M11 (StructureStore / building pieces) + M14 (walkable multi-floor — the vertical-movement
seam this milestone extends).

## Objective

Every Blockfire map today is perfectly flat (`y = 0` everywhere, hardcoded). This milestone adds
**heightmap-based terrain elevation** so maps can have rolling hills, valleys, ridgelines and — via a
cutout mechanism — tunnels, enabling recreation of classic Battlefield-style open terrain layouts.
Terrain must be walkable, must provide real cover (block bullets/LOS), must be driveable, and must
compose cleanly with the existing building/structure system — all server-authoritative,
client-mirrored, deterministic, with **no wire-protocol change** (pawn/vehicle `y` is already fully
replicated).

## Background — the foundation we build on (M14)

M14 (`docs/specs/walkable-multifloor.md`) proved the exact extension seam this milestone needs:

- `shared/sim/sim_loop.gd::_apply_platform_floor(p)` already resolves a pawn's effective floor as
  `maxf(Ladder.platform_floor(...), structures.floor_height_at(...))`, replacing the ground plane with
  whichever standable surface is highest at the pawn's column. Terrain height becomes one more term in
  that same chain.
- `shared/sim/pawn.gd::step()` currently ground-clamps with a **literal constant**:
  ```gdscript
  if pos.y <= 0.0:
      pos.y = 0.0
      velocity.y = 0.0
      grounded = true
  ```
  This is the only place "ground" is hardcoded rather than queried — everywhere else in the sim already
  treats "floor" as a query result, not a constant.
- `shared/sim/fall.gd` (fall-damage curve) only cares about Δy while airborne — terrain-agnostic already,
  confirmed to need no changes.
- Y is already replicated at full precision (`shared/net/quantize.gd`, `POS_SCALE = 1000.0` → 1 mm,
  `i32`) with independent delta bits in `shared/net/snapshot.gd` — the same mechanism that already
  carries building-floor heights carries terrain heights for free.

The gap: there is no elevation *data* anywhere — no map field, no query, no render mesh, no LOS term,
no bot awareness. This spec closes that gap.

## Design

### 1. Heightmap data format

- A grayscale PNG per map, e.g. `maps/heightmaps/proving_grounds.png`, covering
  `[-world_half, world_half]` on both axes.
- **Sample spacing: 2.0 m** — matches `BuildGrid.CELL_SIZE`, so terrain samples and structure cells
  align without a conversion. Chosen over 1.0 m for lower data size, cheaper client mesh vertex count,
  and to keep this project's stated low-end/high-FPS performance priority — the spacing lives behind a
  single constant and can be tightened later if a specific map needs it (YAGNI; not expected).
- Pixel brightness `0–255` maps linearly to `[height_min, height_min + height_scale]`. Both values are
  new `MapDef` fields.
- **New `MapDef.terrain` field** (optional): `{ heightmap: "heightmaps/<name>.png", sample_spacing: 2.0,
  height_min: float, height_scale: float }`.
- **Backward compatible by construction**: maps without `terrain` stay flat
  (`height_at(x,z) == 0.0` everywhere) — `conquest_town`, `conquest_arena_buildings`,
  `conquest_dev_arena`, `conquest_showcase` need zero changes.
- Both server and client parse the same PNG **locally** at map load, exactly like the existing
  "both sides load the same `maps/*.json`/`buildings/*.json`" pattern — no new wire transfer.

### 2. Shared terrain query module

New `shared/sim/terrain.gd` (`class_name Terrain`), pure/stateless like `structure.gd`/`stairs.gd`:

- `Terrain.height_at(grid, x: float, z: float) -> float` — bilinear interpolation of the 4 nearest
  height samples. Continuous everywhere, no faceting artifacts despite grid-sampled source data.
- `Terrain.slope_at(grid, x: float, z: float) -> float` — local slope angle via a central-difference
  gradient of `height_at` itself (continuous, not a per-cell/per-edge value).
- `MAX_WALKABLE_SLOPE_DEG` constant (BattleBit/typical-FPS-like default, ~50°; final value tuned during
  implementation against the demo map).
- `Terrain.resolve_movement(grid, from: Vector3, to: Vector3) -> Vector3` — horizontal blocker in the
  same shape as `structure.gd::resolve_movement`: if the destination column's slope exceeds
  `MAX_WALKABLE_SLOPE_DEG`, the disallowed movement component is clipped (the pawn/vehicle slides along
  the slope face instead of advancing into it). One function covers walking, jumping (jump only adds
  vertical velocity — horizontal advance still runs through this same resolution), and vehicles.

### 3. Server sim integration

- `Pawn.step()` / `_step_downed()`: the literal `pos.y <= 0.0` ground clamp becomes
  `pos.y <= Terrain.height_at(...)`, snapping to the queried height instead of a constant.
- `SimLoop._apply_platform_floor(p)`: terrain height joins the existing `maxf(platform_floor,
  structures.floor_height_at(...))` chain as the new baseline (replacing the implicit `0.0`) — the exact
  seam M14 built, no new mechanism.
- Horizontal movement resolution (`SimLoop`) calls `Terrain.resolve_movement` alongside the existing
  `structures.resolve_movement`, so slope-blocking applies uniformly.
- **Land vehicles**: the same terrain-height and slope-blocking terms are applied to vehicle kinematic
  stepping, so vehicles ride hills (not float/clip) and cannot be driven up an unwalkably steep face.
- **Fall damage**: unmodified — `Fall`/`fall_peak_y` already only track Δy while airborne, so falling off
  a terrain ledge onto lower terrain works automatically.

### 4. LOS / bullet occlusion

`shared/sim/structure.gd::march()` — the shared ray-march used for both LOS checks and bullet hit
resolution — gets a `Terrain.height_at` sample per step: if the ray's height at a given `(x,z)` dips
below terrain height there, the march is blocked, exactly as if it had hit a structure piece. This is
what makes a hill function as real cover rather than a visual backdrop. Bullet march is already
range-bounded (finite travel/lifetime), so this adds a bounded per-step cost, not an unbounded scan —
still worth profiling at the 128-bot gate per this project's "profile, don't guess" precedent (the M11
snapshot-encoder fix).

### 5. Buildings & terrain cutouts

- **Buildings still require a flat footprint** — no sloped-floor structure logic (out of scope; would be
  a much larger expansion of M11/M14).
- **Auto-flatten pad**: at map load, each placed building's footprint AABB is flattened in the loaded
  height data to the terrain height sampled at the building's `origin_cell`. Server and client both
  derive this deterministically from the same source heightmap + building placement list (part of
  `MapDef` load, no wire cost, no divergence risk). `origin_cell.y` is set to the flattened height.
  Removes the need for map authors to hand-paint flat lots under every building.
- **Terrain cutouts (for tunnels)**: a heightmap is inherently 2.5D — one height value per `(x,z)`
  column — so it cannot represent an overhang or a tunnel bored *through* solid terrain on its own. A
  **cutout region** generalizes the auto-flatten mechanism in the other direction: within a declared
  footprint, the heightmap's contribution to the ground term is **suppressed** (excluded from the
  `maxf(...)` chain, or dropped to a low floor value) rather than leveled up, so structure pieces placed
  there fully own that column — exactly like being inside a building today.
  - A tunnel is authored as an ordinary building prefab (corridor of floor/wall/ceiling cells on the
    existing `BuildGrid`) placed inside the cutout, partly or fully below the surrounding grade. No new
    piece types.
  - Entrance/exit mouths are best sculpted directly into the heightmap image as a natural-looking
    depression/ramp leading down to the tunnel opening (blends visually into the hillside); the cutout
    then takes over for the tunnel's interior extent.
  - `march()` treats the tunnel interior exactly like an indoor space once terrain stops blocking there —
    no special-casing needed beyond the cutout suppressing the terrain term.
  - `MapDef.buildings[]` entries gain an optional `terrain_cutout: bool` (or equivalent) flag consumed by
    the same load-time footprint-flatten pass used for building pads, branching to "carve down and
    suppress" instead of "level up."

### 6. Bots

- **Movement**: bots get terrain-following for free — their vertical position already resolves purely
  through `Pawn.step()` + `SimLoop._apply_platform_floor`, both terrain-aware per §3. No new mechanism
  needed for a bot to walk over a gentle hill.
- **Slope-avoidance heuristic** (new, `bots/bot_driver.gd`, bot-only — not sim-authoritative): a bot is
  still blocked by `Terrain.resolve_movement` on a too-steep slope exactly like a human. To keep it from
  getting stuck:
  - **Stuck detection**: track a bot's actual horizontal displacement over the last ~0.5 s. If commanded
    movement is being clipped near-zero by `Terrain.resolve_movement` while the bot is still trying to
    advance, infer "blocked by slope."
  - **Directional choice, not random**: sample `Terrain.slope_at` slightly ahead along both perpendiculars
    to the current heading; steer toward whichever has the shallower slope, biased toward the
    perpendicular closer to the original objective bearing (avoids backtracking). Two cheap extra height
    samples, no search.
  - **Resume**: follow the sidestep heading until no longer clipped or a timeout elapses, then re-aim at
    the objective as normal.
  - **Explicitly narrow scope**: this is slope-specific stuck-avoidance only. It does **not** give bots
    any general building/obstacle pathfinding — that boundary is unchanged from today (no NavMesh/AStar
    anywhere in the codebase), same class of accepted gap as M14's "bots don't path multi-floor
    buildings."

### 7. Client rendering

- `client/world_renderer.gd`'s single flat `PlaneMesh` is replaced by a terrain mesh generated from the
  same heightmap PNG (loaded locally — same "both sides load the same file" pattern as maps/buildings).
- Built 1:1 vertex-per-2m-sample (no separate LOD/decoupled resolution needed given the already-coarse
  2 m spacing).
- **Chunked, not one giant mesh**: the terrain is built as a grid of `MeshInstance3D` chunks (e.g. 64×64
  samples ≈ 128 m tiles) rather than a single draw call for the whole map. This gets Godot's automatic
  per-instance frustum culling for free — the same pattern already used for building pieces — without
  building a custom LOD system. Matters most for `proving_grounds` (`world_half = 1000` → ~1M vertices
  if built as one mesh).
- **No physics collision shape needed** — neither server nor client uses Godot physics bodies for pawns
  (the sim is custom kinematic stepping in `shared/sim/`), so the terrain mesh is purely visual; collision
  stays entirely in the pure `Terrain` queries from §2.

### 8. Wire protocol

**No change.** Confirmed: pawn/vehicle `y` is already replicated at full precision
(`shared/net/quantize.gd`, `POS_SCALE = 1000.0`) with independent per-field delta bits
(`shared/net/snapshot.gd`, `F_POS_Y`/`VF_POS_Y`). Terrain elevation is a bigger range of the same Y that
already works end-to-end (proven under load by M14's floor system). Map/heightmap data itself is a local
asset load, not replicated, matching the existing map/building JSON pattern.

### 9. Map authoring & demo/gate map

- New tool alongside `tools/map_gen.py` (Python) that procedurally generates a **demo heightmap PNG for
  `proving_grounds`**, deliberately containing a mix of terrain features to exercise every mechanic in
  this spec in one map:
  - gentle rolling hills (general walkability + rendering smoothness)
  - a valley (LOS-blocking + fall-damage test)
  - a deliberately too-steep cliff face (slope-blocking test — walk/jump/drive all rejected)
  - flat plateaus around the existing bases/points/buildings (auto-flatten-pad correctness — these should
    need no manual retouching once the flatten pass runs)
  - a short tunnel segment (cutout + building-prefab corridor + sculpted entrance ramp) exercising §5's
    cutout mechanism end-to-end
- **Gate map: retrofit `proving_grounds`** — already the largest, sparsest map (`world_half = 1000`, only
  3 buildings), the natural candidate for rolling terrain; reuses its existing capture points/bases/spawns
  rather than re-authoring a new layout from scratch.

## Out of scope for v1 (explicit)

- **Sub-2m sample resolution** — 2 m chosen deliberately for performance; revisit only if a specific map
  design needs finer detail (YAGNI, per project direction).
- **General bot obstacle/building pathfinding** — the slope-avoidance heuristic (§6) is narrowly scoped;
  bots still have no awareness of walls/buildings beyond what exists today.
- **Sloped building foundations** — buildings remain flat-pad-only; no structure-floor-on-a-slope
  mechanic.
- **Distance-based terrain LOD/mesh decimation** — chunking (§7) gets frustum culling via `MeshInstance3D`
  visibility; no vertex-count reduction by distance. Add only if the gate shows a real cost.
- **Water/rivers** — a separate future feature, not touched here.
- **Terrain destructibility** — craters/deformation from explosives are out of scope; terrain is static
  per-map for v1 (only structures are destructible, per M11).

## Gate

Per project discipline (AGENTS.md §10 — prove mechanics deterministically, bot fleet for scale/perf only):

- **Deterministic mechanic tests:**
  - `Terrain.height_at` bilinear correctness (grid points, midpoints, edges).
  - `Terrain.slope_at` / `Terrain.resolve_movement` slope-blocking (walking, jumping, driving all rejected
    on too-steep terrain; gentle slopes pass through unaffected).
  - `structure.gd::march()` terrain-occlusion (a hill blocks LOS/bullet hit between two points that would
    otherwise see each other on flat ground).
  - Building-footprint auto-flatten-pad correctness (a building placed on sloped terrain gets a flat lot;
    `origin_cell.y` matches the flattened height).
  - Terrain-cutout correctness (a tunnel's interior is unblocked by terrain; `march()` treats it as an
    indoor space; the entrance transition is walkable).
  - Fall damage off a terrain ledge (existing curve, terrain-height-driven `fall_peak_y`/landing).
  - Bot slope-avoidance reroute (a bot facing a too-steep slope changes heading rather than getting stuck
    indefinitely).
  - Client/server `height_at` parity for a set of sample points (M1/M2-style prediction-parity pattern).
- **128-bot fleet gate** on the retrofitted `proving_grounds`: mean tick < 33.3 ms budget maintained,
  match reaches a winner, vehicles/pawns follow terrain correctly under load, no new `[perf]` bottleneck
  (re-profile `move`/`snap`/`march` per the M11 snapshot-cost precedent — don't assume, measure).
- **Human playtest (feel):** hills provide real cover/sightline blocking in a live match, no
  clipping/floating buildings or vehicles, slope-blocking doesn't read as an invisible wall, the tunnel
  reads as a real subterranean space, bot slope-avoidance doesn't visibly loop or break.

## Files (anticipated)

- `shared/sim/terrain.gd` — **new**: `height_at`, `slope_at`, `resolve_movement`, `MAX_WALKABLE_SLOPE_DEG`.
- `shared/sim/map_def.gd` — `terrain` field (heightmap path, sample_spacing, height_min, height_scale),
  optional `terrain_cutout` flag on building placements.
- `shared/sim/pawn.gd` — ground clamp uses `Terrain.height_at` instead of the literal `0.0`.
- `shared/sim/sim_loop.gd` — fold terrain height into `_apply_platform_floor`'s `maxf(...)` chain and into
  horizontal movement resolution alongside `structures.resolve_movement`.
- `shared/sim/structure.gd` — `march()` gains a terrain-height occlusion term; building-footprint
  auto-flatten/cutout pass at map load.
- Land vehicle kinematic step (`shared/sim/` vehicle physics) — terrain height + slope-blocking terms.
- `bots/bot_driver.gd` — stuck-detection + directional slope-avoidance heuristic.
- `client/world_renderer.gd` — chunked terrain mesh generation from the heightmap PNG.
- `tools/map_gen.py` (or a new sibling tool) — demo heightmap generator for `proving_grounds`.
- `maps/heightmaps/proving_grounds.png` — the demo/gate heightmap asset.
- `maps/conquest_proving_grounds.json` — updated with the new `terrain` field + a tunnel building
  placement.
- `tests/` — `terrain_test.gd` (height/slope/resolve_movement), `terrain_march_test.gd` (LOS occlusion),
  `terrain_building_flatten_test.gd`, `terrain_cutout_test.gd`, `terrain_fall_test.gd` (or folded into
  existing `fall_test.gd`), bot slope-avoidance test, client/server height-parity test.

## Open decisions (resolved during brainstorm)

- Terrain model = **heightmap grid with interpolation** (bilinear collision, smooth-shaded render mesh),
  not blocky steps and not arbitrary continuous geometry — standard terrain-engine approach.
- Sample spacing = **2.0 m**, matching `BuildGrid.CELL_SIZE`, chosen for low-end/high-FPS performance over
  visual fidelity; revisit later only if needed (YAGNI).
- Authoring = **grayscale heightmap image**, not procedural noise or a hand-edited raw grid — lets a real
  Battlefield-style layout be sculpted by eye.
- Terrain **does** block LOS/bullets (real cover), not visual-only — core to the milestone's purpose.
- Slope limit = **yes, v1** (blocks walking, jumping, and driving up too-steep terrain) — added during
  brainstorm after an explicit ask; not part of the original framing.
- Buildings = **flat-pad-only** via auto-flatten at map load; no sloped structure floors.
- **Tunnels are possible** via a terrain-cutout mechanism (suppress terrain in a footprint, place an
  ordinary building prefab corridor there, sculpt the entrance in the heightmap) — added during brainstorm
  after an explicit ask; not part of the original framing.
- Bots get **automatic terrain-following** (free) plus a **narrow slope-avoidance heuristic** (added during
  brainstorm after an explicit ask) — but no general obstacle/building pathfinding.
- Gate map = **retrofit `proving_grounds`**, not a new map from scratch.
- A **procedurally generated demo heightmap** exercising every mechanic (hills, valley, cliff, flat
  building pads, tunnel) is a required gate artifact, not an incidental asset.
