# M22 — In-Engine Map Editor & Authoring Loop

- **Status:** code complete (2026-07-17) — **awaiting the owner authoring gate**
- **Owner-directed:** 2026-07-16 — the keystone fix for the visual-polish hurdle.
- **Design:** [`docs/superpowers/specs/2026-07-16-map-editor-design.md`](../superpowers/specs/2026-07-16-map-editor-design.md)
- **Decision:** [ADR-0013](../adr/0013-external-assets-and-procedural-destruction.md) (destructible buildings stay procedural; external assets are non-destructible only).

## Objective

Maps are authored **blind** by Python coordinate-emitters (`tools/map_gen*.py`) with no visual feedback → they look bad (the `conquest_caspian` hand-authoring attempt failed despite rich references). Build a **Godot 4 `EditorPlugin`** (Approach A) that authors maps visually — terrain brush sculpting, grid-snapped destructible-building placement, free-placed props, capture-point/base/spawn markers, and **real road geometry** — saving the existing `maps/*.json` + heightmap format so the running game loads editor output unchanged. Real-mesh preview in the viewport via `@tool` art kits; a **Play-this-map** button for lit WYSIWYG. Puts owner taste in the loop; agents build the deterministic tooling. **Includes the heightmap-precision fix** (currently 8-bit PNG = 256 levels = a 9.4 cm vertical quantum on `conquest_town` → terrain stair-steps). Fixed via **EXR float**, not 16-bit PNG: Godot 4.7's PNG loader truncates 16-bit PNGs to 8-bit (probed 2026-07-17 — see design doc §5.1).

New maps are Battlefield-map-*inspired* originals — **not** real-world DEM imports (owner-directed).

## Scope

See the design doc §2 for the full goals/non-goals. **v1:** terrain sculpt (EXR float), destructible-building placement (procedural slabs, grid-snapped, live-validated), free props/scenery, gameplay markers, **real road ribbon geometry + corridor grade** (not painted splatmap), load/hand-fix existing maps, save + Play. **Deferred:** external Synty/CC0 asset import (ADR-0013 track), manual ladder placement, road splatmap painting, multi-cell terrain tunnels.

## Gate (must pass to close)

- Headless suite green for the pure modules (`TerrainBrush`, `RoadBuilder`, `MapValidator`, `MapDocument` round-trip) + an EXR-float heightmap `Terrain.height_at` parity test + an 8-bit-PNG back-compat test.
- **Owner-validated:** author a small new map end-to-end in the editor and play it; load-and-hand-fix an existing map (e.g. salvage `conquest_town`) and play it.

## Implementation status (2026-07-17)

Built via [`docs/superpowers/plans/2026-07-17-m22-map-editor.md`](../superpowers/plans/2026-07-17-m22-map-editor.md) (14 TDD tasks, subagent-driven; suite **2014 run, 0 failed**; `conquest_town` still boots server-side, `map=Town`, struct=2453).

**Landed:**
- `shared/mapedit/` — pure, headless-tested: `TerrainBrush`, `HeightmapIO`, `RoadBuilder`, `MapValidator`, `MapDocument`.
- `addons/map_editor/` — `EditorPlugin` + dock (5 tool modes, live validation, Save, Play this map) + `EditorPreview` rendering the real runtime art kits (`BuildingKit`/`SceneryKit`, never forked).
- **Heightmap precision fixed** — float EXR replaces 8-bit PNG. The old path gave 256 levels = a 9.4 cm quantum at `height_scale: 24.0` (the stair-stepping). **16-bit PNG was tried and rejected: Godot 4.7's loader truncates it to 8-bit** (probed). Legacy PNG maps still load (back-compat test). Editor saves migrate the heightmap to `.exr`.
- **Real roads** — `roads[]` gains a spline form (`{"spline": [[x,z]…], "width": f}`) rendering as a draped ribbon on terrain maps, replacing the painted splatmap. `RoadBuilder.corridor_grade` (landed + unit-tested) regrades the heightmap under a road along the long terrain trend without flattening the surrounding world. Legacy AABB roads and the splatmap path still work; every existing map renders unchanged.

**Deferred (unchanged from the design doc §8):** external asset import, manual ladder placement, road splatmap detailing over the ribbon, multi-cell terrain tunnels. **Also deferred to the owner gate:** the road tool draws the spline + ribbon but does not yet auto-invoke `corridor_grade` — whether drawing a road should regrade its corridor (and on what trigger: per-point, on save, or a separate "grade roads" action) is a destructive terrain edit best decided against the live authoring feel. The regrade is a proven module ready to wire behind whichever trigger the owner prefers.

**Still open:** the gate below is owner-only — a GUI authoring loop cannot be headless-tested. Enable via **Project → Project Settings → Plugins → BlockFire Map Editor**.
