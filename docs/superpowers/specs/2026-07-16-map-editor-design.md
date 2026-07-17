# Design — M22: In-Engine Map Editor & Authoring Loop

- **Status:** approved (brainstormed 2026-07-16)
- **Milestone:** [M22](../../milestones/M22-map-editor.md)
- **Related:** [ADR-0013](../../adr/0013-external-assets-and-procedural-destruction.md) (procedural destruction / external assets), [heightmap-terrain spec](../../specs/heightmap-terrain.md), `docs/specs/destructible-buildings.md`
- **Approach:** A — Godot 4 `EditorPlugin` (chosen over an in-game editor mode and a hybrid).

## 1. Problem & purpose

Maps are the project's biggest visual-quality gap. Today a "map" is authored **blind** by Python coordinate-emitters (`tools/map_gen*.py`) with **no visual feedback loop**: the author types cell coordinates into a script that emits a `maps/*.json` + a heightmap PNG, then renders it to find out it looks wrong. This is why hand-authored maps have repeatedly failed (the `conquest_caspian` attempt looked nothing like its references despite screenshots, top-down maps, and hand-drawn diagrams).

The fix is to **put a human with taste into the authoring loop** with a real visual tool. AI agents build the deterministic tooling and pipelines (their strength); the owner authors the maps by hand, seeing the result (a taste task agents fail).

A "map" in BlockFire is three things, all currently blind-authored:
1. A greyscale **heightmap PNG** (`maps/heightmaps/*.png`) → terrain shape (loaded by `shared/sim/terrain.gd::load_for_map` → `build_grid`).
2. A **`maps/*.json`** with `world_half`, `points[]`, `bases[]`, `buildings[]` (prefab + `origin_cell` + `yaw`), `scenery[]`, `ladders[]`, `platforms[]`, `prebuilt[]`.
3. Procedurally-generated **models** (`client/art/building_kit.gd`, `tree_kit.gd`, `rock_kit.gd`).

## 2. Goals / non-goals

**Goals (v1):**
- A Godot `EditorPlugin` that authors maps visually and saves the **existing** `maps/*.json` + heightmap format unchanged (the running game loads editor output with no code path divergence).
- Terrain brush sculpting; grid-snapped destructible-building placement; free-placed props/scenery; capture-point/base/spawn markers; **real road geometry** (not a painted texture); live validation.
- Load any existing map to fix by hand (immediate salvage of the bad generated maps).
- Real-mesh preview in the editor viewport + a "Play this map" launch button for lit WYSIWYG.
- Fix the heightmap to **16-bit** (kills terrain stair-stepping).

**Non-goals (deferred to v2+):**
- External Synty/CC0 asset import (its own track, [ADR-0013](../../adr/0013-external-assets-and-procedural-destruction.md)); the prop palette is extensible but v1 ships the existing kits.
- Manual ladder placement (keep the current roof-ladder generator for now).
- Road/sidewalk **splatmap painting** — replaced by real road meshes.
- Multi-cell terrain tunnels/cutouts authoring (single-cutout only, as today).
- Any change to destructible buildings' geometry model — they stay procedural slabs (ADR-0013).

## 3. Architecture

A Godot 4 `EditorPlugin` under `addons/map_editor/`. It reuses the Godot editor's 3D viewport, camera, transform gizmos, and native undo/redo (`EditorUndoRedoManager`). The editor is **editor-only** — it ships in `addons/`, never in an exported client `.pck`.

```
addons/map_editor/
  map_editor_plugin.gd      EditorPlugin: registers dock + viewport tool, routes input, owns undo
  ui/
    editor_dock.gd/.tscn    tool-mode selector, prefab/prop palettes, per-object inspector, Save/Play
  preview/
    editor_preview.gd       instantiates the real @tool art kits → real meshes in the viewport
shared/mapedit/             (pure, headless-testable — see §4)
  map_document.gd           in-memory model + load/save (maps/*.json + heightmap PNG)
  terrain_brush.gd          pure heightmap brush ops
  road_builder.gd           pure: spline → ribbon mesh + corridor grade
  map_validator.gd          pure: overlap / on-road / coverage checks (port of the Python validator)
```

All pure modules live in `shared/mapedit/` (outside `addons/`) so the running game and headless tests can use them — the runtime road renderer depends on `RoadBuilder`, and `MapValidator` is reused at runtime. The `addons/` code is the thin editor shell that imports from `shared/mapedit/`.

### Data flow
- **Load:** `MapDocument.load(map_name)` reads `maps/<name>.json` + `maps/heightmaps/<name>.png` into an editable in-memory model (terrain height array, building list, prop list, points, bases, roads).
- **Edit:** viewport/dock tools mutate the `MapDocument` through undoable operations; `EditorPreview` re-renders affected objects with real meshes; `MapValidator` runs on change and surfaces problems in the dock.
- **Save:** `MapDocument.save()` writes the `maps/*.json` (with the new `roads[]`) and bakes the terrain (including road corridor grade) to a **16-bit** heightmap PNG.
- **Play:** the Play button launches the game (`godot --path . -- --map <name> ...`) on the saved map.

## 4. Modules (interfaces)

### `MapDocument` (pure data + serialization)
- `static load(map_name) -> MapDocument` / `save() -> void` — round-trips the existing format plus `roads[]`.
- Holds: `terrain` (float height array + dims + `world_half`/`height_min`/`height_scale`), `buildings[]`, `props[]` (from `scenery`), `points[]`, `bases[]`, `roads[]`.
- No editor dependency → headless round-trip tests (load→save→reload is stable).

### `TerrainBrush` (pure)
- `static apply(heights, cols, rows, spacing, center_xz, radius, strength, mode) -> void` where `mode ∈ {RAISE, LOWER, SMOOTH, FLATTEN}`. Falloff is a smooth radial kernel. FLATTEN targets a sampled/held height.
- Deterministic; unit-tested on small grids (monotonic raise, smooth reduces variance, flatten converges).

### `RoadBuilder` (pure)
- `static ribbon_mesh(spline_pts, width, height_sampler: Callable) -> ArrayMesh data` — a draped ribbon (quads along the centerline, sampling terrain height per vertex, small vertical offset + shoulder edges).
- `static corridor_grade(heights, dims, spline_pts, width, sigma) -> void` — applies the wide-Gaussian corridor smoothing (the established `gen_town_heightmap` regrade) so the road holds a smooth consistent grade over the long trend without flattening the surrounding world.
- Roads are cosmetic: pawns/vehicles still resolve on terrain height, so **no sim/wire change**. The corridor grade is part of the terrain the sim already reads.
- Unit-tested: ribbon vertex count/winding, drape follows sampler, corridor grade monotonically smooths along the centerline.

### `MapValidator` (pure)
- `static check(doc) -> Array[String]` — building/building overlap, building-on-road, capture-point/base coverage & bounds, spawn validity. Ports the assertions in `tools/map_gen.py`'s validator into GDScript.
- Runtime + editor + tests all call it. Unit-tested against known-good and known-bad fixtures.

### `EditorPreview` (editor-only)
- Instantiates the real runtime art kits (`building_kit`, `tree_kit`, `rock_kit`) under `@tool` to render placed objects with real meshes/materials; rebuilds incrementally on document change. Any kit script that must run at edit-time gets a `@tool` annotation + a guard for editor-absent singletons.

### `map_editor_plugin.gd` + `ui/editor_dock.gd` (editor-only)
- Tool modes: **Terrain** (brush), **Building** (grid-snap prefab place/rotate/delete), **Prop** (free transform place/scatter), **Marker** (points/bases/spawns), **Road** (spline place/drag). Each mutation is wrapped in `EditorUndoRedoManager`.
- Dock: mode selector, prefab palette (from `buildings/*.json`), prop palette (from the scenery kits), per-selection inspector (radius, yaw, owner, road width), a live validation panel, **Save**, **Play this map**.

## 5. Runtime changes (minimal, needed to render editor output)

1. **16-bit heightmap load** — `terrain.gd::load_for_map`/`build_grid` reads a 16-bit greyscale PNG (65536 height levels) instead of 8-bit. Save side writes 16-bit. Parity-tested: `height_at` on an editor-saved map matches the intended profile within tolerance; existing 8-bit maps still load (auto-detected by image format) so nothing regresses.
2. **Road-ribbon renderer** — a small client renderer builds `RoadBuilder.ribbon_mesh` for each `roads[]` entry at map load (server ignores roads; they're cosmetic). Reuses the terrain height sampler already present client-side.

No wire/protocol change. No `Protocol.VERSION` bump. Server sim untouched (roads cosmetic, terrain already heightmap-driven).

## 6. Testing & gate

**Headless (house pattern, deterministic):**
- `TerrainBrush`, `RoadBuilder`, `MapValidator`, `MapDocument` round-trip unit tests.
- 16-bit heightmap round-trip + `Terrain.height_at` parity (game loads editor-saved map, heights match).
- Load→save→reload stability on an existing map (no unintended drift).

**Owner-validated (GUI can't be headless-tested — client-feel gate pattern):**
- **Gate:** the owner authors a small new map end-to-end in the editor (sculpt terrain, place buildings + props, draw a road, set points/bases) and plays it; **and** loads an existing map (e.g. salvages `conquest_town`), edits it by hand, and plays it. Headless suite green.

## 7. Resolved decisions (no open questions)

- **Editor form:** Godot `EditorPlugin` (Approach A). Real-mesh preview via `@tool` kits; lit WYSIWYG via the Play button.
- **Roads:** real ribbon geometry + heightmap corridor grade, cosmetic (no sim change); **in v1**.
- **Terrain:** in-editor brush sculpting; 16-bit heightmap.
- **Existing maps:** loadable and hand-fixable in v1.
- **Destructible buildings:** stay procedural slabs, grid-snapped placement only (ADR-0013).
- **External assets / ladder placement / splatmap roads / tunnels:** deferred (§2).

## 8. Deferred / follow-ups

- External-asset import pipeline (Synty/CC0 props) feeding the prop palette — ADR-0013 track.
- Manual ladder placement tool; auto-ladder regen on save.
- Road splatmap/decal detailing on top of the ribbon (sidewalks, markings).
- Multi-cell terrain cutouts/tunnels authoring.
- A "generate scaffold then hand-edit" bridge (import a `map_gen` output as a starting `MapDocument`) — already implicitly supported via load, but a template/brush-preset library could speed greenfield maps.
