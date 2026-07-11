# M11 — Destructible Buildings

**Status:** P1+P2+P3 sim + **P4 Gate-B feel** implemented & merged · **Gate A (128-bot sim) PASS ✅ 2026-06-23** · **Gate-B feel built + owner-playtested across several live rounds (2026-07-06/07)** — real see-through holes / shoot-through / walk-through, balanced destruction, BattleBit collapse (warning + walkable rubble ruins), all 128-bot-gated (suite 1372/0) · **Remaining:** owner's final feel sign-off at the **joint playtest** (the two new gate buildings it waited on have landed — procedural, see below); R6 (organic collapse), corner destructibility, and cosmetic BuildingKit tweaks deferred · **Coordinates with:** M5.5-P3 (melee sledge/pickaxe). Spec: [`destructible-buildings.md`](../specs/destructible-buildings.md) (ratified 2026-06-18).

**Objective:** BattleBit-style destructible **map buildings** — almost all walls/interiors/stairs destructible with chain-reacting structural collapse — on the M4 `BuildGrid`/`StructureStore`/`PieceCatalog` substrate, within the M4 event/interest/cap discipline.

## Scope
- **Two granularities:** pieces (2.4 m cells; structure/support/collapse) + **sub-cell chunks** (8×8 = 64-bit alive-mask per piece face; holes/chipping).
- **Unified** `StructureStore` — every piece is chunked; M4 player-building refactored onto it and **re-gated** (one destruction codepath).
- **Support-reachability cascade:** destroying load-bearing pieces orphans unsupported pieces (chain reaction); large orphan sets degrade to a single **whole-building collapse** event → walkable rubble.
- Damage from **explosives** (M4 frag + M4.5 RPG) and **melee** (sledge). **Bullets do not carve building walls** (per-type catalog flag; player fortifications keep M4 bullet vulnerability).
- **Fully procedural** building art kit + per-building rubble; **client cosmetic layer** (holes/debris/collapse cinematic), never networked.
- **Risk:** the tick is snapshot-dominated (~29–32 ms vs 33.3 at 128p), so M11 adds **no systematic per-tick cost** — chunk damage + cascade are event-driven, replication reuses the M4 delta cap + carry, collapse is one event, steady-state adds only a single bit-test in the ray-march hit. The unify refactor made the M4 re-gate mandatory.

## Gate (split)
- **Gate A — sim (128-bot headless):** holds tick < 33.3 ms + bandwidth; chunks destroyed, pieces removed, a cascade fires, ≥1 collapse, replicates to bots, Conquest reaches a winner; **plus a full M4 re-gate**.
- **Gate B — feel (owner playtest):** holes/debris/collapse cinematic on the rendered client (AGENTS.md §10).

## Sim — P1 (chunked store) + P2/P3 (catalog, cascade, procedural art) — done ✅ 2026-06-18
Branch `m11-destructible-buildings` → `m11-p2-p3-buildings`; subagent-driven TDD. **P1:** `ChunkMask` (64-bit sub-cell mask), `PieceCatalog` gains `chunk_grid`/`structural`/`damage_types` (+ `SRC_BULLET|EXPLOSIVE|MELEE`), `StructureStore` record carries `chunks`+`building_id` with spatial `damage_chunks(id, source, impact, radius)` honouring per-type immunity, protocol `OP_DAMAGE`→`OP_CHUNK{id, mask:u64}`, bot+client mirrors apply `OP_CHUNK`, server fire/blast carve chunks under the M4 delta cap. Hole-aware march **descoped at P1** (later phase). **P2/P3:** unified `pieces/pieces.json` with bullet-immune building pieces (`bwall`/`bwall_window`/`bwall_door`/`bfloor`/`bstair`/`bcolumn`/`brailing`/`prop_crate`), `BuildingCatalog` prefab loader (`buildings/*.json`), `MapDef.buildings[]`, `Support` cascade flood-fill (`shared/sim/support.gd`), `StructureStore` building index, `Msg.COLLAPSE`, procedural `client/art/building_kit.gd`. Suite 536/0; deterministic functional proof `tests/server_buildings_functional_test.gd` (damage→cascade→orphan→collapse). *(The 2026-06 P1 re-gate was recorded as unit 461/0 + branch≡master parity because the combat AI was mid-rewrite/inert at the time; the AI has since landed and fires.)*

## Gate A (128-bot sim fleet) — PASS ✅ 2026-06-23
On game2 (Docker full, server P-cores 0-3), `conquest_proving_grounds` (struct=177, TICKETS=80):
`winner=1 t0=0 t1=43 elapsed=447s < 900 cap_events=4, peak tick=24.65 ms < 33.3, destroyed=17 rstruct=25 collapsed=1 (emergent whole-building COLLAPSE) dmg=22 nades=24 rockets=4, agg 15.7 Mbit/s, 0 script errors`. Evidence `docker/srvlog-m11-20260623-191111.log`. Scripts `docker/run-m11-gate.sh` + `ci/m11_buildings_test.sh` (`--map`-parameterised). Every criterion met; M4 re-gate satisfied by the green unit suite + this run holding budget with one destruction codepath. Mechanic proof `server_buildings_functional_test.gd` / `support_test.gd` / `protocol_collapse_test.gd`.

**Map-scale finding (RESOLVED 2026-07-01):** dense maps pushed snapshot-baseline cost to the ceiling (`conquest_town` 8324 pieces exceeded budget). Root cause was the delta ENCODER, not cascade/collapse — `EntityState.bake()` quantizes wire fields once per send (encode −52%, bit-identical) and `conquest_town` now PASSES at **27.31 ms** (`docker/srvlog-m11-20260701-160937.log`).

## P4 client cosmetics + Gate-B feel (hole-aware destruction) — built & owner-playtested 2026-07-06/07
Branch `m11-gate-b-feel` (owner chose **full BattleBit walk-through holes**). Harness `tools/render_destruct_shots.gd`. What shipped:
- **Hole-aware geometry (H1):** a partially-carved chunked wall is promoted out of the batched whole-mesh into a per-chunk hole grid (only ALIVE 0.25 m chunks render); pristine pieces never promote → no steady-state cost.
- **Hole-aware march (H2):** `StructureStore.march` does one `ChunkMask.is_alive_at` bit-test at the contact point — a cleared chunk passes shots/rockets/LOS. **128-bot gate PASS on conquest_town** (`winner=1 peak tick 23.22 ms<33.3 destroyed=18 rstruct=44 collapsed=2, 0 errors`).
- **Walk-through (H3):** `_blocks_ground` returns not-solid once `ChunkMask.region_clear` finds the pawn's body column carved open at floor level (shoot-through before walk-through, as in BattleBit).
- **Collapse:** footprint-scaled dust cinematic + ~7 s rumble/shake warning (`COLLAPSE_WARNING` msg) then walkable **INDESTRUCTIBLE `brubble` ruins** stamped across the ORIGINAL footprint (real collision, at the building's actual floor `cell.y`).
- **Balance (current constants):** carve radii **frag 0.4 m / RPG 1.3 m / C4 2.2 m** (grenades don't breach); walls bear load until nearly destroyed (`SUPPORT_MIN_FRACTION` 0.12); whole-building collapse needs ~half the pieces orphaned (`COLLAPSE_FRACTION` 0.5); irregular holes via deterministic no-RNG rim jitter; a shot-down stub becomes vaultable (`ChunkMask.top_alive_height`); floors/stairs keep the batched mesh (only vertical walls get sub-cell holes).
- Fixed a latent M11-P1 bug: `ChunkMask` face U-axis/origin now match the renderer for every yaw (E/W walls were drawing the mirror of the carved chunk). Suite 1372/0.

## Two new gate buildings + 2.4 m cell overhaul — landed 2026-07-07
The two buildings the final sign-off waited on are **procedural** (owner chose the procedural Kenney-quality path, not a third-party kit): `manor` (wide 3-storey) + `rowhouse` (tall narrow terrace), via `build_gen.py` + `build_fix.py` with Kenney pieces (parapet, keystoned windows/doors, corner quoining) and one entrance per face. Placed on `conquest_town` (23 buildings). **128-bot Gate-A re-run PASS** (game2, 2026-07-07): `winner=1 elapsed=79s peak tick=22.60 ms < 33.3, struct=2459 destroyed=2 rstruct=9 collapsed=0, 0 errors` (`docker/srvlog-m11-20260707-211246.log`). Also lands the **`BuildGrid.CELL_SIZE 2.0→2.4`** global-cube change + collateral fixes (rubble stamped at true floor `cell.y` on hills; per-cell rubble spin/scale/tint so ruins read organic; `BF_NOFX`/`BF_CORNER` QA env). Suite 1379/0.

## Deferred
- **Corner destructibility:** `bwall_corner` is an L of two perpendicular faces but `ChunkMask` is single-face, so a carved corner promotes to one flat slab. **Owner decision (2026-07-07):** implement the **shared-mask** approach (render + carve both arms from one 64-bit mask; accepted trade-off — a hole in one arm mirrors on the other away from the join), sequenced as a focused pass with one combined 128-bot re-gate. **Interim:** `bwall_corner` excluded from client promotion (keeps a clean L-mesh, not yet breachable). See [[blockfire-corner-destruction-deferred]].
- **R6** organic/non-scripted collapse; GPU-particle debris + far-LOD; 3 cosmetic BuildingKit geometry tweaks (lintel clip, railing/stair height).
- **Gate B = owner's final feel sign-off at the joint playtest.**
