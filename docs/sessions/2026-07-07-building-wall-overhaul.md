# Building wall overhaul — edge-alignment fix + Kenney-quality pieces (2026-07-07)

Handoff for whoever continues the building-look work. This session fixed the long-standing "walls look
wrong" problem (corner crosses / gaps / inset walls / overhanging roof) that multiple prior agents could
not resolve, improved window/door/corner geometry toward the Kenney reference, and ported the fix into
the live game. **All destructible via the existing M11 chunk system — no third-party assets, no
destruction regression. Full suite 1372/0.**

## The root cause that finally solved the wall issue (READ THIS FIRST)

Building walls are **thin slabs (0.3 m) placed in a 2 m cell**. The bug every prior attempt chased:

1. A wall's **outward direction cannot be derived from its yaw.** `buildings/*.json` reuses ONE yaw per
   opposing pair — **N and S rows are both yaw 0, E and W columns are both yaw 2** (a symmetric slab
   looks identical at yaw 0 vs 4). So "push the wall out along its facing" shoves one wall of each pair
   outward and the opposite one **inward**. That was the real defect (owner spotted "only S/E indented").
2. With walls sitting on the **cell mid-line**, they're ~0.85 m inside the building footprint, so the
   roof (which spans the full cell) overhangs them and any separate corner piece either protrudes
   (edge arms / pilaster) or gaps/crosses (centred) — you can never close the corner by editing the
   corner piece alone.

**Fix:** compute each wall's outward direction from its **cell position vs the building centre** (not
yaw) and shift the piece OUT to the footprint edge along its thin axis (yaw%4==0 → Z axis, else X).
Then straight walls, corner edge-arms, and the roof edge all land on the same footprint plane — flush
corners, no X, no gaps, no overhang.

## Where the fix lives

- **Preview:** `client/art/preview/building_preview.gd` `_build_building` — computes building cell-centre
  and offsets each `bwall*` (not `bwall_corner`) outward. Also added a **`--debug=true`** diagnostic
  mode (unshaded flat colours per piece keyed by facing: walls S/W/N/E = red/green/blue/yellow, corner
  = magenta, floor = grey; shadows off). **Use `--debug=true --noroof=true` top-down to diagnose ANY
  wall/corner geometry bug** — it makes the plan unambiguous where a lit iso hides it. Owner asked to
  reuse this for designing future buildings.
- **Game:** `client/world_renderer.gd` — `_rebuild_structure_batches` builds `_building_bounds`
  (building_id → cell footprint, from RAW cells to avoid a circular ref with `_building_footprint`), and
  `_structure_xform` applies the same outward offset. **Critical:** both the pristine batched mesh AND
  the M11 promoted hole-chunk geometry derive from `_structure_xform`, so a carved hole stays exactly on
  the wall automatically. Verified in-game with `tools/render_destruct_shots.gd --rendering-driver opengl3`
  (intact → hole → breach → rubble): walls edge-aligned, hole on the wall face, see-through.

## Kenney-quality piece geometry (`client/art/building_kit.gd`)

Improved toward the Kenney low-poly reference, all as shallow relief over the CELL-wide carvable slab so
M11 chunk-hole promotion stays seamless (the slab is what carves; trim/glazing harmlessly drop):
- `bwall_window` — large framed opening, recessed glazing + mullion cross, proud sill/trim.
- `bwall_door` — framed opening, recessed panelled leaf, proud jamb/lintel surround.
- `bwall_corner` — reverted to the edge-arm L (matches the now edge-aligned straight walls).

## Verified findings — do NOT "optimise" these away

The workaround cleanup was investigated empirically and the candidates are **load-bearing**:
- **Floor-skirt** (`building_kit.gd` `floor_skirt`) is REQUIRED — without it the interior goes floorless
  (rendered `--skirt=false --noroof` to confirm). Edge-alignment did NOT make it redundant.
- **bfloor z-fight fudges** — still needed (roof/wall coplanarity).
- No dead `BuildingKit` functions (all referenced).
- Minor note: the skirt's concrete "base ledge" tone assumed the slab overhung the wall's EXTERIOR
  (centred wall). With edge-aligned walls that lip is now on the INTERIOR — eyeball it next visual pass.

## Remaining work (next agent)

1. **Cell height → 2.4 m (owner-chosen: global cube).** Change `BuildGrid.CELL_SIZE` + `BuildingKit.CELL`
   + `StructureKit` hardcoded 2.0 widths together, regenerate maps (`tools/map_gen*.py`), run the suite
   (absolute-value tests will need updates). **Remove the `bwall_door` "reach into the cell above" hack
   here** — it only exists for 2 m ceilings and becomes valid to delete at 2.4 m.
2. **Author 2 new Kenney-quality buildings + place on conquest_town.** These are the gate items the
   owner's final M11 sign-off waits on (`docs/milestones/M11-destructible-buildings.md` lines 3/173).
   Run the 10-view + `--debug` top-down QA sweep, `tools/build_fix.py`, then the 128-bot gate.
3. **Roofline polish** — parapet/cornice + a deliberate (small) eave instead of the full-cell reach.

## Context / decisions

- Decision: author our OWN destructible box pieces to the Kenney *look* (reference only) — NOT import
  third-party meshes (they'd swap to box-debris on M11 damage + provenance). See the earlier spike gallery.
- The `spike/` folder (Kenney/Quaternius CC0 kit import experiment) was intentionally NOT committed.
- Render host: the dev laptop (`.128`, godot 4.7, wayland). Preview: `building_preview.tscn`.
