# M22 — In-Engine Map Editor & Authoring Loop

- **Status:** in-progress (design approved 2026-07-16)
- **Owner-directed:** 2026-07-16 — the keystone fix for the visual-polish hurdle.
- **Design:** [`docs/superpowers/specs/2026-07-16-map-editor-design.md`](../superpowers/specs/2026-07-16-map-editor-design.md)
- **Decision:** [ADR-0013](../adr/0013-external-assets-and-procedural-destruction.md) (destructible buildings stay procedural; external assets are non-destructible only).

## Objective

Maps are authored **blind** by Python coordinate-emitters (`tools/map_gen*.py`) with no visual feedback → they look bad (the `conquest_caspian` hand-authoring attempt failed despite rich references). Build a **Godot 4 `EditorPlugin`** (Approach A) that authors maps visually — terrain brush sculpting, grid-snapped destructible-building placement, free-placed props, capture-point/base/spawn markers, and **real road geometry** — saving the existing `maps/*.json` + heightmap format so the running game loads editor output unchanged. Real-mesh preview in the viewport via `@tool` art kits; a **Play-this-map** button for lit WYSIWYG. Puts owner taste in the loop; agents build the deterministic tooling. **Includes the 16-bit heightmap load fix** (currently 8-bit → terrain stair-steps).

New maps are Battlefield-map-*inspired* originals — **not** real-world DEM imports (owner-directed).

## Scope

See the design doc §2 for the full goals/non-goals. **v1:** terrain sculpt (16-bit), destructible-building placement (procedural slabs, grid-snapped, live-validated), free props/scenery, gameplay markers, **real road ribbon geometry + corridor grade** (not painted splatmap), load/hand-fix existing maps, save + Play. **Deferred:** external Synty/CC0 asset import (ADR-0013 track), manual ladder placement, road splatmap painting, multi-cell terrain tunnels.

## Gate (must pass to close)

- Headless suite green for the pure modules (`TerrainBrush`, `RoadBuilder`, `MapValidator`, `MapDocument` round-trip) + a 16-bit heightmap `Terrain.height_at` parity test.
- **Owner-validated:** author a small new map end-to-end in the editor and play it; load-and-hand-fix an existing map (e.g. salvage `conquest_town`) and play it.
