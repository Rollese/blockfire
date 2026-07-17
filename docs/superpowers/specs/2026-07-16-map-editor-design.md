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
- Fix heightmap **precision** (kills terrain stair-stepping) — via **EXR float**, *not* 16-bit PNG. See §5.1: Godot 4.7's PNG loader truncates 16-bit PNGs to 8-bit, so "16-bit PNG" is not implementable.

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
- **Save:** `MapDocument.save()` writes the `maps/*.json` (extending the existing `roads[]` with a spline form) and bakes the terrain (including road corridor grade) to a **float EXR** heightmap.
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

1. **Float heightmap (EXR)** — *revised 2026-07-17 after an engine probe; supersedes the original "16-bit PNG" plan.*

   **The bug is real:** heightmaps are 8-bit greyscale PNG → 256 levels. On `conquest_town` (`height_scale: 24.0`) that is a **9.4 cm vertical quantum** — the visible stair-stepping.

   **But 16-bit PNG does not work in Godot 4.7.** Probed directly (`Image.load` of a true bitdepth-16 greyscale PNG): the loader returns `FORMAT_L8` and the sampled values are 8-bit-truncated (`0.015686` where 16-bit would give `0.015873`). Saving a `FORMAT_RH` image via `save_png()` silently downconverts to `RGB8`. PNG cannot carry sub-8-bit-quantum height in this engine.

   **Decision: EXR float.** Probed round-trip on the same engine:

   | Format | Worst abs error | Over `height_scale: 24.0` |
   |---|---|---|
   | 8-bit PNG (today) | `1/255` | **94 mm** per level |
   | EXR half (`FORMAT_RGBH`) | `4.8e-4` | 11.6 mm |
   | **EXR float32 (`FORMAT_RF`)** | `3.0e-8` | **~0 (exact)** |

   `save_exr(..., grayscale=false)` → `Image.load` round-trips float32 losslessly. Editor saves EXR; `terrain.gd::build_grid` already reads `.r` per pixel and `load_for_map` already converts to `FORMAT_RGBF`, so **the load path needs no maths change** — only the extension/format branch. Existing 8-bit PNG maps keep loading unchanged (branch on the `terrain.heightmap` file extension), so nothing regresses.

2. **Road-ribbon renderer** — *revised 2026-07-17: `roads[]` is **not** new.*

   Today roads exist in **two** forms, both of which the editor must reckon with:
   - `roads[]` = axis-aligned AABB strips (`{"min":[…], "max":[…]}`), parsed by `MapDef` and rendered by `world_renderer.gd:661` as **flat `PlaneMesh` strips at y=0.04** — and *skipped entirely on terrain maps*, because a flat plane buries under a hill.
   - `terrain.surface_map` = a **road/sidewalk splatmap** painted into the terrain shader (`world_renderer.gd:357`). This is the "painted on terrain" the owner wants replaced, and it is how `conquest_town`'s roads render today.

   v1 **extends** `roads[]` with an optional spline form — `{"spline": [[x,z], …], "width": float}` — alongside the legacy AABB form. `MapDef` parses both; `RoadBuilder.ribbon_mesh` renders spline roads as real draped geometry on terrain maps. Legacy AABB roads and the splatmap path stay working untouched (back-compat: every existing map keeps rendering as it does now). Roads remain cosmetic — pawns resolve on terrain height — so **no sim/wire change**.

No wire/protocol change. No `Protocol.VERSION` bump. Server sim untouched (roads cosmetic, terrain already heightmap-driven).

## 6. Testing & gate

**Headless (house pattern, deterministic):**
- `TerrainBrush`, `RoadBuilder`, `MapValidator`, `MapDocument` round-trip unit tests.
- EXR float heightmap round-trip + `Terrain.height_at` parity (game loads editor-saved map, heights match to <1 mm); an 8-bit PNG map still loads unchanged (back-compat).
- Load→save→reload stability on an existing map (no unintended drift).

**Owner-validated (GUI can't be headless-tested — client-feel gate pattern):**
- **Gate:** the owner authors a small new map end-to-end in the editor (sculpt terrain, place buildings + props, draw a road, set points/bases) and plays it; **and** loads an existing map (e.g. salvages `conquest_town`), edits it by hand, and plays it. Headless suite green.

## 7. Resolved decisions (no open questions)

- **Editor form:** Godot `EditorPlugin` (Approach A). Real-mesh preview via `@tool` kits; lit WYSIWYG via the Play button.
- **Roads:** real ribbon geometry + heightmap corridor grade, cosmetic (no sim change); **in v1**. Extends the existing `roads[]` with a spline form; legacy AABB roads + `surface_map` splatmap keep working (§5.2).
- **Terrain:** in-editor brush sculpting; **EXR float** heightmap (not 16-bit PNG — §5.1).
- **Existing maps:** loadable and hand-fixable in v1.
- **Destructible buildings:** stay procedural slabs, grid-snapped placement only (ADR-0013).
- **External assets / ladder placement / splatmap roads / tunnels:** deferred (§2).

## 8. Deferred / follow-ups

- External-asset import pipeline (Synty/CC0 props) feeding the prop palette — ADR-0013 track.
- Manual ladder placement tool; auto-ladder regen on save.
- Road splatmap/decal detailing on top of the ribbon (sidewalks, markings).
- Multi-cell terrain cutouts/tunnels authoring.
- A "generate scaffold then hand-edit" bridge (import a `map_gen` output as a starting `MapDocument`) — already implicitly supported via load, but a template/brush-preset library could speed greenfield maps.
