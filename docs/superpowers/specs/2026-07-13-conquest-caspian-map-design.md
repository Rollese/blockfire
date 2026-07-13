# Conquest map: `conquest_caspian` — design

_Status: draft for review · 2026-07-13 · Track: core-priority "real maps" (AGENTS.md §12)_

## 1. Purpose

A new large Conquest map for BlockFire modelled on **Battlefield 4 / BF3 Caspian
Border** — a five-flag border-crossing battlefield reinterpreted for
**infantry-only** play (all vehicles are deferred, AGENTS.md §12). It gives the
project its first deliberately-designed "real map" with a strong tactical
identity: a north–south push across a **fully-destructible border wall**, over
rolling heightmap terrain with a commanding central hill, forest cover, and a
river.

Success = a `maps/conquest_caspian.json` (+ heightmap + surface splatmap) that
loads server + client + bots, plays a full 128-player Conquest match, and passes
the standard 128-bot fleet gate, with the layout recognisably Caspian Border.

## 2. Authoritative layout reference

The canonical spatial source is the owner's annotated image
**`~/Downloads/caspian_drawing.png`** — hand-drawn directly on top of the real
BF map. All flag/base positions, roads, river, border line, and rock formations
are traced from it. Legend:

| Colour | Meaning |
|---|---|
| Green | Play-area boundary (irregular, tall, slightly tilted) |
| Red | Capture points (A–E) and US / RU deployments |
| Black | Main paved highway (single NW→SE diagonal) |
| Blue | River (N–S, loops the Hilltop, exits south) |
| Yellow | Border wall — 5 m concrete blocks + barbed wire, E–W |
| Brown | Dirt roads / footpaths |
| Grey | Rock formations |

Reference screenshots consulted: BF wiki flag descriptions (Antenna, Checkpoint,
Forest, Gas Station, Hilltop) supplied by the owner; overview map
`caspian_border2.jpg` (Conquest Large flag/base placement); pure-terrain
`caspian_border.jpg`.

## 3. Scale & orientation

- **`world_half = 500.0`** → 1000 m × 1000 m playable square (~1 km²).
  Owner-chosen 2026-07-13: roughly half the real Caspian footprint
  (~1.5–1.8 km across) — BattleBit infantry-scale, with five flags given real
  breathing room. Flag cluster ends up ~150–280 m apart: far enough that terrain
  and forest break most **flag-to-flag sightlines**, so players must reposition
  to engage the next point rather than trading fire across capture zones.
  Worst-case base-to-front opening walk ~350–450 m, mitigated because owned
  flags **and** squadmates are spawn points (only the first push walks far), and
  each deployment is placed near its own owned flags.
- **North = −Z, South = +Z, East = +X.** US deploys north, RU deploys southwest.
- Coordinates are traced from the reference image and normalised into
  `[-380, +380]` on X/Z during generation. The exact metre coordinates are
  produced by the generator (§9) and are not hand-fixed here; the image governs
  relative placement.

## 4. Flags, bases, ownership

Five capture points (Conquest Large A–E) plus two deployments.

| ID | Name | Side of border | Rough position | Identity |
|---|---|---|---|---|
| A | Antenna | US (north) | East flank | Rock-ringed vantage; climbable tower |
| B | Checkpoint | On the line | West-centre | Most-developed border post + highway crossing |
| C | Forest | Contested centre | Centre | The only flag with **no emplacement**; open, ridge sniping |
| D | Hilltop | RU (south) | Centre, below B | Central rocky rise; all-flag vantage; river-wrapped |
| E | Gas Station | RU (south) | South-centre | Developed village; RU-side |
| — | US deploy | North | North-centre | Staging (no-fight) |
| — | RU deploy | Southwest | SW corner | Industrial fuel depot |

**Start ownership** (drives the north–south border push):

- US owns **A + B** (`start_owner: 0`)
- RU owns **D + E** (`start_owner: 1`)
- **C Forest neutral** (`start_owner: -1`) — the contested centre.

`bases[]` has exactly one team-0 and one team-1 entry (required by `MapDef`).
Owned flags auto-become spawn options through the existing `DeploySpawn` system;
no new spawn code.

**Capture radius:** ~24 m per point (matches existing maps' feel).

## 5. Terrain (heightmap)

A single grayscale heightmap PNG (`maps/heightmaps/conquest_caspian.png`,
~501×501 samples at `sample_spacing: 2.0` for the 1000 m span) with a `terrain`
block (`height_min`/`height_scale` TBD by the generator, target ~35 m total
relief so the central Hilltop commands the field and ridges/forest break
flag-to-flag LOS). Features, composed procedurally the way
`gen_proving_grounds_heightmap` / `gen_town_heightmap` already work:

- **Hilltop (D):** a genuine central rise commanding sightlines to every flag,
  with forest masses breaking LOS. Footpaths on all sides; one graded (walkable,
  ≤ `MAX_WALKABLE_SLOPE_DEG`) approach; a lower ridge across the service road
  gives the south vantage on the slope but not the crown.
- **Ridges / outcrops** around Antenna and Forest — low rises that host the rock
  scenery and give sniping perches on otherwise open ground.
- **River channel:** a shallow sunken depression traced along the blue line
  (N–S, wrapping the Hilltop's east side, exiting south). Cover for movement; no
  swim mechanic — it reads as a creek/dry-ish channel, walkable.
- **Rolling elsewhere** — no flat parade ground; gentle swells for real cover.
- Building pads auto-flatten onto the slope via `Terrain.load_for_map` +
  emitted `footprint` AABBs (existing behaviour).

Roads are baked into a **surface splatmap** PNG
(`maps/heightmaps/conquest_caspian_surface.png`, R=asphalt for the highway,
G=sidewalk/dirt border) exactly as `gen_town_surface_map` does, so they conform
to terrain with no z-fighting.

## 6. The border wall (signature feature)

An E–W run of destructible concrete blocks along the border line (yellow in the
reference), ~5 m tall with a barbed-wire cap.

- **Construction:** a repeated wall segment (~2 m / one build cell wide) stamped
  cell-by-cell into the same `StructureStore` that runs M11 building
  destruction, spanning the play-area width along the border. Assembled from
  existing catalog pieces — `bwall` / `bwall_brick` for the concrete body,
  stacked to ~5 m, `brailing` on top to read as barbed wire. No new piece type
  is strictly required; a thin authored `border_wall` prefab (a vertical stack
  of these pieces) is stamped repeatedly by the generator.
- **Fully destructible:** every block is a normal structure chunk, so any
  explosive/melee damage breaches it (bullets don't damage walls, per M11). The
  wall funnels players for the opening minutes, erodes into gaps, and can end a
  match nearly levelled — no special-case code, it just rides M11.
- **Start openings:**
  1. **B Checkpoint** — the main highway crossing (a wide gap with the border
     post structures around it).
  2. **Gate** — where the A→E dirt road crosses the line (an authored gate:
     `bwall_door` / `bwall_garage` piece span, destructible).
  3. **1–2 pre-existing breaches** — short gaps elsewhere along the run.
- **Perf note:** the wall adds many small chunks to `StructureStore`. Budget it
  against the M11 dense-map baseline (`conquest_town` = 8324 pieces passed the
  128-bot gate at 27.31 ms). Keep total map piece count in that neighbourhood;
  the fleet gate is the backstop (§10). If over budget, coarsen block width or
  shorten the wall to the play-area width only.

## 7. Per-flag structures

Existing prefabs (`buildings/*.json`) unless marked *bespoke-assembled* (built
from existing catalog pieces, not a brand-new art asset). Available prefabs
include: apartment, barn, barracks, bunker, cottage, factory, family_a/b,
gas_station, guardhouse, hangar, house, lhouse, manor, office, office_tower,
parking, rowhouse, shed, silo, supermarket, tower, townhouse, twostory_house,
villa, warehouse. Available piece types: `bwall`(+brick/metal/wood/glass/half),
`bwall_door/window/corner/garage`, `bfloor`, `bstair`, `bcolumn`, `brailing`,
`sandbag`, `heavy_barricade`, `fob`, `prop_crate/barrel/table/…`, `brubble`.

| Flag | Structures |
|---|---|
| **A Antenna** | `tower` prefab as the mast base + *bespoke-assembled* upper platforms (`bfloor` + `brailing`) reached by `bstair`/ladders → the signature climbable vantage; a `guardhouse` or `bunker` at the base; rock scenery ring. |
| **B Checkpoint** | Border post: `guardhouse` ×2, `barracks`, `shed`; cargo containers (*bespoke* `heavy_barricade` / `bwall_metal` boxes / `prop_crate` stacks); the highway gap; river/creek cover alongside. Most-developed flag. |
| **C Forest** | **No emplacement** (canon). Open ground, rock outcrops, dense tree scenery for sniping perches; 1–2 portable buildings (`shed`/`cottage`) near the gate crossing between C and A. |
| **D Hilltop** | Rocky crown, footpaths; *bespoke-assembled* small **radio tower** (destructible — `bcolumn`/`tower` pieces + `brailing`); minimal hard cover so terrain does the work. |
| **E Gas Station** | `gas_station` prefab + a small village (`house`, `twostory_house`, `cottage`, `family_a/b`); *bespoke-assembled* **water tower** (`silo` + legs, destructible); scattered cover. Developed RU-side base. |
| **US deploy** | A few `shed`/tents + sandbags — staging, no-fight. |
| **RU deploy** | Industrial fuel depot: `warehouse` + `factory` + `silo` storage tanks. |

Where a "bespoke" landmark proves too costly in Phase 1 it is approximated by the
nearest existing prefab and upgraded in Phase 2 (§8) — the map stays playable
throughout (foundation-first, [[blockfire-visible-progress-morale]]).

## 8. Roads & scenery

- **Roads** (`roads[]` AABBs + baked into the surface splatmap):
  - Main highway — NW→SE diagonal through the B crossing, out the SE.
  - E–W service road along the border.
  - A→E dirt road — full east-flank run US → Antenna → … → Gas Station,
    crossing the border at the gate.
  - RU basin path network (SW) linking RU deploy, Hilltop, and Gas Station.
- **Scenery** (`scenery[]`, client-only MultiMesh): forest tree masses at C and
  around the map edges; rock formations ringing Antenna, crowning the Hilltop,
  and scattered near US/RU (traced from the grey marks). Palettes from
  `data/scenery_catalog.json`.

## 9. Implementation approach

Author via a **Python generator**, the canonical pattern for this project's maps
(`tools/map_gen.py` produced `conquest_town` + heightmap + splatmap;
`gen_proving_grounds_heightmap` is a worked heightmap example). New generator
`tools/map_gen_caspian.py` (or a `gen_caspian_*` section in `map_gen.py`) emits:

1. `maps/conquest_caspian.json` — `world_half`, `points[]` (A–E with ownership),
   `bases[]` (US/RU), `buildings[]` (prefab stamps + the repeated border-wall
   segments + bespoke landmarks), `roads[]`, `ladders[]` (antenna/tower),
   `scenery[]`, `platforms[]` (antenna/tower decks), `terrain` block,
   `vehicle_spawns: []` (kept empty — guarded by
   `map_def_test.gd::test_shipping_maps_have_no_vehicle_spawns`).
2. `maps/heightmaps/conquest_caspian.png` — grayscale heightmap.
3. `maps/heightmaps/conquest_caspian_surface.png` — road surface splatmap.

Register in the rotation (`data/server_config.example.json` `"maps"`), runnable
immediately with `--map=conquest_caspian` (server + client + bots must match).

Files touched/created:
- **New:** `tools/map_gen_caspian.py`, `maps/conquest_caspian.json`,
  `maps/heightmaps/conquest_caspian.png`, `maps/heightmaps/conquest_caspian_surface.png`,
  possibly `buildings/border_wall.json` (+ any bespoke landmark prefabs).
- **Edited:** `data/server_config.example.json` (rotation); TASKS.md/milestone
  board entry (added at plan time).
- **Read/validate against:** `shared/sim/map_def.gd`, `shared/sim/conquest.gd`,
  `shared/sim/deploy_spawn.gd`, `shared/sim/terrain.gd`,
  `shared/sim/building_catalog.gd`, `docs/specs/heightmap-terrain.md`.

### Phasing (playable fast, polish second)

- **Phase 1 — playable + gate-testable:** JSON + heightmap + splatmap; all
  flags/bases/ownership/spawns; roads; existing-prefab buildings; the
  destructible border wall with B crossing + gate + breaches; registered in
  rotation. Landmarks approximated where needed. Deliverable: a full match runs
  and the 128-bot fleet gate passes.
- **Phase 2 — landmark polish:** bespoke climbable antenna tower, water tower,
  radio tower, refined gate + cargo containers, breach tuning, scenery density
  and rock/ridge placement passes against the reference image.

## 10. Test plan / gate

- **Deterministic (authoritative):**
  - `map_def` validation — map loads, required-field rules pass, `vehicle_spawns`
    empty (existing `map_def_test.gd` guards).
  - A `conquest_caspian`-specific check (extend `map_buildings_test.gd` /
    `map_ladders_test.gd` style): every flag present with correct ownership;
    both bases present; antenna ladder tops land on real walkable decks; border
    wall spans the border with the intended openings; no building overlaps
    (reuse the generator's overlap validation).
- **Fleet gate (load/perf/stability, per AGENTS.md §6/§8):** 128-bot Docker
  match on `conquest_caspian` on game2, P-core-pinned server. PASS = full match
  to a winner, peak tick < 33.3 ms, script_errors = 0, capture events > 0. Record
  evidence in `docs/gate-evidence/`. Watch the piece-count/tick budget (§6 perf
  note).
- **Owner feel-gate (Phase 2):** live desktop-client playtest — the border-wall
  funnel-then-breach arc reads right, flags feel Caspian, terrain gives cover,
  landmarks recognisable. (Bot tactical *feel* is out of scope here — that's
  M7.5, AGENTS.md §10.)

## 11. Out of scope / deferred

- **Vehicles** — no spawns, no vehicle-tuned sightlines (AGENTS.md §12). If the
  vehicles milestone reopens, Caspian is a natural candidate to re-widen.
- **Brand-new art assets** — barbed wire, water/radio-tower, container, and gate
  meshes are approximated from existing catalog pieces; dedicated art is a later
  art-pipeline item ([[blockfire-art-pipeline-track]]), not this map.
- **Bot pathfinding/navmesh tuning** for the new terrain — reuse existing bot
  nav; log shortfalls as M7.5 items rather than blocking this map's gate.
- **Second Conquest size variant** (4-flag) — could drop Antenna later; not now.

## 12. Open questions

- Exact `height_scale` / relief amount and river-channel depth — tune in the
  generator against the fleet-gate freeze-safety lessons from M15 (no hard
  pad-edge cliffs; keep slopes walkable).
- Final border-wall block count vs. tick budget — measured at the first fleet
  gate; coarsen if needed (§6).
- Whether the border wall is one authored `border_wall` prefab stamped N times
  or generated inline — an implementation choice for the plan.
