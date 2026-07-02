# Building Overhaul — Diagnosis & Design Proposal (for review)

**Status:** EXECUTED in substance (2026-06-20/21 building-overhaul sessions — see `docs/sessions/2026-06-20-playtest-building-overhaul.md` + `docs/runbooks/building-kit.md`); never formally ratified — treat the shipped code as authoritative where this text diverges — needs owner design decisions + a playtest-driven iteration loop
(buildings are visual; each pass needs an eyeball). Written 2026-06-19 from playtest feedback. Pairs
with M14 (walkable multi-floor, done) and supersedes the round-1/round-2 ad-hoc prefab edits.

## Playtest feedback (2026-06-19)

> "Buildings still don't have coherent walls, there are gaps in the walls and they don't look very
> good… The tower is bare with just columns and floors, no walls on it. Floors are too low, the
> ceiling should be high up. Blowing up buildings works, but entire wall sections disappear at once,
> not 'bricks'."

## Root-cause diagnosis (why the walls have gaps)

The building system is on a **2 m cubic grid, one piece per cell**, and the wall pieces are **thin
slabs centred in their cell** (`client/art/building_kit.gd`: `bwall` = `2 × 2 × 0.3 m` at the cell
centre; `bcolumn` = a `0.5 × 2 × 0.5 m` post at the cell centre). Three consequences:

1. **Corners don't close.** A yaw-0 wall (spans X, thin in Z) sits at its cell's *mid-Z line*; an
   adjacent yaw-2 wall (spans Z, thin in X) sits at its cell's *mid-X line*. The two thin slabs are a
   full cell apart and meet as an offset "L" — the actual corner (cell boundary) is empty. Gap.
2. **Corner columns make it worse.** The current house/bunker put a `bcolumn` (a 0.5 m post) at each
   corner cell. A 0.5 m post in a 2 m cell leaves ~1.5 m of open space on each side between the post
   and the neighbouring wall slabs. Big gaps.
3. **Collision doesn't match the visual.** Structure collision is **whole-cell** (you're blocked from
   entering any occupied cell), but the wall is a thin slab inside that cell — so you bump an
   invisible boundary ~1 m off the visible wall, and partial damage (sub-cell chunks) is computed but
   **not rendered** (the wall is drawn pristine until the whole piece is removed → "sections vanish,
   no bricks").

Plus two authoring gaps (not engine bugs): the **tower has no wall pieces at all** (12 columns + 19
floors + 2 stairs), and the buildings are **single-cell-tall (2 m ceilings)** — cramped.

**Bottom line:** coherent, good-looking buildings are not really achievable on the 2 m cell-centred
thin-wall model. This is the limitation the finer-piece overhaul (owner-greenlit earlier) is meant to
remove. Patching the current prefabs would still look rough — the fix is the piece model.

## Style target (low-poly, blocky — general principles)

The reference look is a low-poly, blocky shooter (Roblox/Minecraft-adjacent): simple, **readable
real-world building types** (house, warehouse, supermarket, tower), **coherent enclosed shells** with
obvious doors/windows, **simple roofs** (flat for industrial, low-pitch for houses), all
**destructible**. Geometry stays cheap (few polys) for long draw distances and mass destruction. We
build our *own* geometry to these principles — no third-party assets (see "Assets" below).

## Solution approaches (pick one)

**A — Blocky full-cell walls (cheapest, ~content + small kit change).** Make `bwall` render as a
*full-cell* block face (fills the cell footprint, butts cleanly against neighbours → corners close,
collision matches the whole-cell model). Windows/doors are full-cell blocks with a carved opening.
Buildings become chunky but coherent and on-style. Stays on the 2 m grid. **Fastest path to
"coherent + no gaps", lowest risk.** Loses fine detail (everything is 2 m chunky); 2 m-thick walls.

**B — Edge-aligned walls + sub-cell collision (medium).** Render walls on the cell *edge* facing
out (by yaw) so a perimeter ring forms a closed shell on the building's true outline, AND add a
thin sub-cell collision slab so the invisible-wall mismatch goes away. Keeps thin walls (less chunky
than A) but needs a collision change (the structure store gains per-piece face collision) — touches
the movement hot path.

**C — Finer sub-cell grid (biggest; the original "finer pieces" ask).** Add 1 m (or 0.5 m) placement
granularity so walls, columns, windows, and trim can coexist and align — true modular-kit detail
(columns *and* continuous walls at corners, varied wall widths). Touches `BuildGrid`, collision, the
chunk model, and replication — a milestone in itself, and the only path that fully delivers the
"different wall sizes" + fine detail the owner asked for.

**Recommendation:** **A now, C later.** Ship **A** (blocky full-cell walls + re-authored buildings)
as the next building round — it fixes "incoherent walls / gaps / bare tower / low ceilings" quickly,
matches the whole-cell collision, and is firmly on-style; it's verifiable and low-risk. Then schedule
**C** (finer grid) as the milestone that adds detail/variety once the blocky base reads well. (B is a
middle option if A looks too chunky in the playtest.) This also unblocks the brick-by-brick
destruction: render the per-chunk damage mask on the full-cell walls (the M11-P4 cosmetic layer) so
walls chip instead of vanishing.

## New piece set (Approach A) — proposed

Full-cell, blocky, with carved openings; each a distinct silhouette + colour (we already have a
per-type palette). Walls 1 cell tall; stack 2 for taller rooms (M14 makes upper floors walkable).

- `wall_solid`, `wall_window` (cell with a window void), `wall_door` (cell with a door void, already
  `passable`), `wall_garage` (wide bay door — warehouses), `wall_storefront` (large glass front —
  supermarket), `wall_half` (low wall / parapet, `height: half`).
- `roof_flat` (industrial cap), `roof_pitch` (low-pitch gable mesh — houses) + `roof_eave` trim.
- `floor` (have it), `stair` (have it; M14 walkable), `pillar` (interior support), `beam` (lintel).

## New buildings (after the kit) — owner's list

`warehouse` (large flat-roof box, garage bays, open interior + a mezzanine via M14), `house_2story`
(pitched roof, rooms, walkable upstairs), several `house_family_*` single-story variants (footprint /
roof / window variety), `supermarket` (large storefront glass, flat roof, open interior with shelf
props). Author every elevated piece supported (M11 cascade) and ceilings ≥ 2 cells where it reads as
a room.

## Assets — note for the record

We will **not** extract or import BattleBit (or any commercial game's) meshes/textures — that's
copyright infringement even as placeholders and would contaminate the project. All building geometry
is our own procedural low-poly kit, informed only by the general low-poly style (which is not
protectable). If we ever want richer art, the route is **CC0 / self-made** assets (the M7-P2 GLB kit
already uses Quaternius CC0), never ripped game files.

## Open decisions for the owner

1. Approach **A / B / C** for the next round (recommend A now, C as a later milestone).
2. OK to make walls **blocky/full-cell** (2 m thick, chunky) as the trade for coherence?
3. Brick-by-brick destruction (render the chunk-damage mask = M11-P4) in this round, or after?
4. Confirm the building list + which to build first.
