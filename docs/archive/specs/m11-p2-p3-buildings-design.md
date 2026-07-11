# M11 P2+P3 — Destructible map buildings (implementation design)

**Date:** 2026-06-18 · **Status:** design approved, ready for implementation plan
**Parent spec (brainstorm-of-record):** `docs/specs/destructible-buildings.md` (ratified 2026-06-18)
**Milestone:** `docs/milestones/M11-destructible-buildings.md`
**Builds on:** M11-P1 chunked `StructureStore` (DONE — `ChunkMask`, `PieceCatalog` `chunk_grid`/`structural`/`damage_types`, `StructureStore.damage_chunks`, `OP_CHUNK`).

This document scopes the implementation of **P2 (support cascade + collapse)** and **P3 (building
authoring + procedural art)** together, so the playtest has real destructible buildings to fight in
and destroy. It does not re-litigate the ratified mechanics in the parent spec; it fills in the
authoring layer, the cascade, the art, and the build order.

## Goal

Get **three destructible building archetypes** onto `proving_grounds`, destructible by **explosives
(RPG + frag)** and a minimal **melee** hook, with **chain-reacting structural collapse → rubble**.
The complete destruction loop, verified deterministically headless.

## Build order (6 work-streams)

### 1. Building piece catalog — single rewritten `pieces/pieces.json`
The existing `pieces/fortifications.json` is **rewritten into one unified catalog** `pieces/pieces.json`
holding every piece type (player fortifications + building pieces) in a single `pieces[]` array.
No second file, no merge step. `PIECES_PATH` in `server_main` is updated to the new path; the old
`fortifications.json` is removed. Wire `type` = index into this one array; stable order is
`sandbag(0)`, `wall(1)`, then the building pieces below:

| id | height | structural | chunk_grid | damage | role |
|----|--------|-----------|-----------|--------|------|
| `bwall` | full | true | 8 | explosive, melee | solid wall |
| `bwall_window` | full | true | 8 | explosive, melee | wall w/ window gap |
| `bwall_door` | full | true | 8 | explosive, melee | wall w/ doorway |
| `bfloor` | full | true | 8 | explosive, melee | floor/ceiling slab |
| `bstair` | full | true | 8 | explosive, melee | inter-floor stair |
| `bcolumn` | full | true | 8 | explosive, melee | load-bearing column |
| `brailing` | half | false | 4 | explosive, melee | non-structural guard |
| `prop_crate` | half | false | 1 | explosive, melee | non-structural cover prop |

All building pieces are **bullet-immune** (Decision A): `damage: ["explosive","melee"]` — no
`"bullet"`. Player-built `sandbag`/`wall` keep `bullet` (M4 preserved). `material`/`health` per the
existing catalog schema (`health` > 0 required; `blocks: "both"` only, v1).

Client `STRUCT_TYPE_ID` / `STRUCT_TYPE_GRID` mirror this single-file order exactly (the existing
`["sandbag","wall"]` array grows to include the building pieces in the same positions).

### 2. Prefab format + loader — `buildings/*.json`, `BuildingCatalog`
```json
{
  "name": "bunker",
  "pieces": [
    {"type": "bwall_door", "offset": [0, 0, 0], "yaw": 0},
    {"type": "bwall",      "offset": [1, 0, 0], "yaw": 0, "structural": true}
  ]
}
```
- `offset` = integer **cell offset** (Vector3i) relative to the building origin; `yaw` = step
  index `0..7` (`BuildGrid.YAW_STEPS`). `structural` optional override (else catalog default).
- New `shared/sim/building_catalog.gd` (pure, `RefCounted`): `from_dict`/`from_json_string`/
  `load_file`, validates each piece type exists in the `PieceCatalog`, offsets are 3-int, yaw in
  range. Refuses bad prefabs (server won't start). Unit-tested, no engine deps.

### 3. Map placement + server stamping — `MapDef.buildings`, `server_main`
- `MapDef` gains `buildings: [{prefab:String, origin_cell:Vector3i, yaw:int}]`, parsed + validated
  alongside `prebuilt` (3-int origin, yaw in range, prefab name non-empty).
- At server start, for each map building instance: assign a unique `building_id` (monotonic,
  starting at 1; loose/player pieces stay `0`), rotate each prefab piece's `offset` by the instance
  `yaw`, add `origin_cell`, and `StructureStore.place(type, cell, yaw+piece_yaw, owner=-1,
  building_id)`. Reuses the existing `prebuilt` stamping path.

### 4. Support + cascade — `shared/sim/support.gd`, `COLLAPSE` protocol
- Pure module over `StructureStore`:
  - `foundation_ids(store, building_id)` → structural pieces with `cell.y == 0`.
  - `orphaned_after(store, building_id, removed_ids)` → flood-fill from the foundation over
    same-`building_id` **face-adjacency** (6-neighbour cells; columns also connect vertically);
    any structural piece **not reached** is orphaned. Resolves the full fixed point in one pass.
    Pure, bounded by building size, unit-tested.
- **Server integration:** after any structural piece is removed by `damage_chunks` (mask hit 0),
  run `orphaned_after` for that `building_id`. Remove orphans (→ more `OP_REMOVE`). If
  `|orphaned| + 1 > COLLAPSE_THRESHOLD`, emit a single **`Msg.COLLAPSE {building_id:u16}`** and
  remove the whole building instead of streaming per-piece removes. All under the existing
  `MAX_STRUCTURE_DELTAS_PER_TICK` cap (large cascades amortise across ticks).
- `protocol.gd`: add `Msg.COLLAPSE` (next free id), encode/decode round-tripped.

### 5. Procedural building art + client rendering
- New `client/art/building_kit.gd` paralleling `StructureKit`: procedural low-poly geometry per
  building piece type (no team-tint, matches M7-P2 kit), with whole→damaged→destroyed visual states
  driven by the **chunk-mask damage bucket** (already wired in `world_renderer.damage_bucket`).
- Per-building **rubble model** (a low procedural debris mound) swapped in on `COLLAPSE`.
- Client `WorldRenderer`: extend `STRUCT_TYPE_ID` / `STRUCT_TYPE_GRID` for the new types and route
  building piece types to `BuildingKit.build` (fortifications still use `StructureKit`). Handle
  `COLLAPSE`: remove the building's piece nodes, spawn rubble; **light** cinematic only (sink +
  smoke + existing AudioDirector rumble) — full debris-particle polish is out of scope here.
- All cosmetic, never authoritative.

### 6. Bots + verification
- `bots/bot_driver.gd`: heuristic to lob frag / fire RPG at buildings near contested objectives
  (reuse the M4 fortification-targeting heuristic). Best-effort; not a gate.

## Verification

No owner-playtest gate for this work — the project-wide playtest happens later, once all agents'
features have landed and passed headless testing. This feature is gated on **headless tests only**:

- **Unit:** support flood-fill (orphan sets, collapse-threshold boundary), `BuildingCatalog` +
  `MapDef.buildings` loaders, building-piece bullet-immunity, `building_kit.json` catalog validation,
  `COLLAPSE` protocol round-trip, unified-catalog load + `type`-index order stability.
- **Deterministic functional (headless, no bot AI):** stamp a prefab into a live `StructureStore` →
  fire a **scripted** RPG/blast at known cells → assert chunks carved → structural piece removed →
  `orphaned_after` removes the expected pieces → `COLLAPSE` emitted for the tower when the base
  columns go → rubble state set. Deterministic per [[blockfire-deterministic-testing]]; avoids the
  inert combat-AI path per [[blockfire-ci-smoke-bots-inert]].
- **Boot smoke:** headless server boots clean on a map carrying `buildings[]`.
- The 128-bot full-match **Gate A** (tick/bandwidth/winner) from the parent spec is **deferred**
  while combat AI is mid-rewrite; re-run it once AI stabilises.

## The three archetypes (2 m cells; `CELL_SIZE = 2.0`, `MAX_STACK = 8`)

- **Bunker** — 1 story, ~4×4 footprint of `bwall` with one `bwall_door` + one `bwall_window`, a
  `bfloor` roof. Tests holes + cover.
- **Two-story house** — ~4×5, a `bfloor` slab at `y = 2`, a `bstair` linking levels, windows/door.
  Tests interior destruction + multi-level cascade.
- **Tower** — ~3×3 footprint, ~6 cells tall, four `bcolumn` pieces as the load-bearing spine with
  `bfloor`/`brailing` per level. Collapse showcase: destroy the base columns → everything above
  orphans → `COLLAPSE` → rubble.

Instances placed at/near points **A, C, E** on `maps/conquest_proving_grounds.json` (origin cells
derived from each point's world position via `BuildGrid.cell_of`).

## Scope boundaries (YAGNI)

- **Melee** → chunk hook is the minimal server-validated version (per parent spec M11 owns it);
  **explosives are the primary destruction path**.
- **Hole-aware march** (shooting *through* a partial hole) stays **deferred** (P1 decision): pieces
  block ray + movement until fully removed; partial holes are cosmetic.
- Collapse cinematic is **light** (sink + smoke + rumble + rubble swap); GPU brick-debris particles
  and far-LOD mesh swaps are not in this scope.
