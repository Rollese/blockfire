# ADR-0013: External art assets are for non-destructible content only; destructible structures stay procedural

- **Status:** Accepted
- **Date:** 2026-07-16
- **Context milestones:** M4/M11 (building & destruction), M7-P2 (art pipeline), M22 (map editor & authoring loop), any future asset-import work

## Context

The project's visual quality is the current top pain point. Procedurally-generated building/prop geometry (`client/art/building_kit.gd`, `tree_kit.gd`, `rock_kit.gd`) is a taste-dependent construction task that AI agents do poorly, and hand-authored maps have failed repeatedly (see M22 context: blind coordinate-emitting Python generators with no visual feedback loop).

Two solution pulls collided historically: (a) "use professional low-poly asset packs (Synty POLYGON, Quaternius, Kenney) so the world looks like a real game," and (b) "keep BattleBit-style destructible buildings." **A previous agent tried replacing our procedural slab walls with solid building meshes and broke the destruction system entirely** — the meshes could not be split or holed at runtime. This ADR records the boundary so it is never re-litigated.

## Decision

### 1. Destructible structures MUST remain procedural slabs

The destruction system (`shared/sim/structure.gd` chunked `StructureStore`: 0.25 m sub-cell chunk masks, support-cascade collapse, runtime hole carving + re-meshing — the M4/M11 core) fundamentally requires walls to be **our own procedural geometry that can be split and re-meshed with holes at runtime**. A solid, artist-authored mesh (Synty et al.) is opaque to this system: it cannot be sub-divided, holed, shot through, or collapsed.

**Therefore: any structure that can be damaged, holed, or collapsed stays a procedural slab.** Destruction + gunplay feel are the game's most important pillars (owner-directed, M11) — they are not negotiable against art. Improving how destructible buildings *look* is done via **better textures/materials and non-destructible detail props attached to the slab shell** (AC units, pipes, signs, awnings that pop off when the wall behind them is destroyed) — not by replacing the shell with a mesh.

### 2. External asset packs are for NON-destructible content

Professional low-poly packs are adopted for everything that never needs runtime destruction:

- **Props / set-dressing** (fences, sandbags, barrels, crates, market stalls, streetlights, signs, generators, wrecks) — the biggest "maps stop looking empty" lever.
- **Environment** (rocks, cliffs, vegetation) — upgrades the foliage kit.
- **Characters + weapons** (may replace the GLB character/weapon kits).
- **Vehicles** (deferred track) + **non-destructible structures** (cover-only bunkers/walls).

Agents own the **import + collision-bake + LOD plumbing** (deterministic, testable — an agent strength); artists (the pack authors) own the meshes (a taste task agents fail).

### 3. Vehicle models with functional turrets are supported

A GLB vehicle is cosmetic over the existing vehicle sim (seats, gunner role, mounted-weapon turret offset). The turret sub-mesh is parented to a node rotated to the gunner's aim each frame. If a pack fuses turret-to-hull, a one-time Blender split separates it. (Applies when the deferred vehicle track reopens — recorded here so the capability is known.)

### 4. Asset-pack procurement is de-risked free-first

Build the import/clutter pipeline with **free CC0 packs (Quaternius / Kenney / Poly Pizza)** first and confirm the visual payoff on a real map, **then** purchase paid packs (e.g. Synty POLYGON Military, ~$150) once the pipeline is proven and the payoff is seen. Avoids spending before the pipeline exists.

## Consequences

- `building_kit.gd` and the destructible-building catalog stay procedural. Art improvements to destructible buildings go through materials/textures + detachable detail props, not mesh replacement.
- A new asset-import track (agent-owned plumbing) feeds props/environment/characters into maps; the M22 map editor's palette pulls from it.
- The [art-pipeline spec](../specs/art-pipeline.md) and [destructible-buildings spec](../specs/destructible-buildings.md) reference this boundary.
- Reversible only by a future ADR that also solves runtime destruction of arbitrary meshes (not on the roadmap).
