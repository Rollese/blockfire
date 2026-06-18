# Spec: Destructible Buildings (M11)

**Status:** approved (brainstorm complete; not yet implemented) · **Date:** 2026-06-18 ·
**Milestone:** M11 (proposed) — *spec authored now; implementation sequenced after the M7 rendered
client lands* (the cosmetic layer is owner-playtest-gated and needs rendering).

BattleBit-style destructible **map buildings** — almost all walls, interiors, and stairs can be
destroyed, with chain-reacting structural collapse — built directly on the M4
`BuildGrid`/`StructureStore`/`PieceCatalog` substrate and the M4 event-based, interest-scoped,
capped structure replication. Stays server-authoritative; all rules live in `shared/` so client and
server can't diverge (AGENTS.md §5, §7). The gate is **split**: the destruction *sim* is 128-bot
headless-gated (deterministic, tick + bandwidth budget); the *feel* (holes, debris, collapse
cinematic) is **owner-playtest-gated** on the rendered client — the established M4.5/M7 pattern.

> Read `docs/specs/building.md` (M4 Phase 1) and `docs/specs/destruction.md` (M4 Phase 2) first.
> This spec **unifies** with that substrate: every piece becomes chunked (see §2), so M4 is
> refactored and **re-gated** as part of M11.

## Reference behaviour (BattleBit, confirmed 2026-06-18)

- Walls are **immune to small-arms fire**; only **explosives** (C4/RPG/grenade/tank) and **melee**
  (sledgehammer/pickaxe) destroy structure. Bullet *penetration* (shooting through thin material)
  is a separate ballistics mechanic (M5.5) and does **not** carve walls.
- Walls look **solid when whole**; damage chips them into small blocks. Holes are **localized** to
  the impact (RPG on the left → only the left crumbles). Destroyed walls never look identical —
  not from randomness, but because the **damage input** (impact point / weapon / accumulation) is
  continuous and never repeats over a discrete chunk grid.
- Buildings have **load-bearing structure** (e.g. corner steel columns). Destroy enough and the
  whole building **collapses**: shake + audio rumble → smoke spawns at the building → it shakes and
  sinks into the ground (the sink **masked by the smoke**) → replaced by a **static destroyed
  (rubble) model** with nothing left to destroy. Big "proper houses" take **many** explosive hits.

The mechanism is a discrete grid of small chunks **disguised as bricks** (texture + cosmetic
debris), not per-brick physics. M11 reproduces the *gameplay* of this — and goes slightly past it
on collapse (chain-reacting support cascade vs. mostly all-or-nothing) — while keeping the
netcode coarse and deterministic.

## Scope (ratified in brainstorm, 2026-06-18)

| In scope (this milestone) | Deferred / out of scope |
|---|---|
| **Two granularities:** pieces (2 m cells; structure/support/collapse) + **0.25 m sub-cell chunks** (8×8 alive-mask per piece face; holes/chipping) | Per-brick **authoritative** physics (forever — coarse chunk-mask only) |
| **Unify** `StructureStore`: every piece carries a 64-bit chunk alive-mask; M4 player-building refactored onto it and **re-gated** | **Client-divergent** destruction; **rigid-body tumbling** as gameplay |
| **Hole-aware** ray-march/cover (a shot through a dead chunk passes through) | **Terrain/ground** deformation (buildings only, v1) |
| **Support-reachability cascade**: destroying load-bearing pieces orphans unsupported pieces → removed (chain reaction); degrades to a **whole-building collapse** event for large orphans | Per-piece **repair** (masks only ever lose bits in v1) |
| **Procedural building art kit** (walls/window/door/floor/stair/column/railing + props) with whole→damaged→destroyed states + per-building **rubble** model | **Bespoke** hand-modelled buildings; CC0 import (fully procedural chosen) |
| **Furniture/props** as lightweight **non-structural** destructible cover pieces | Building **resource/economy**; dynamic player-built *multi-cell* buildings |
| **Client cosmetic layer** (M7): solid-until-damaged LOD, MultiMesh hole rendering, GPU-particle brick debris, masked collapse cinematic (shake/rumble/smoke/sink → rubble swap) | Grenade in-flight VFX beyond what M4/M7 already cover |
| Damage sources: **explosives** (reuse M4 frag + M4.5 RPG) + **melee** (sledge/pickaxe, coordinated with M5.5-P3) | **Bullets** carving building walls (immune by catalog flag) |

## Design decisions (ratified)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Milestone framing | **New milestone (M11); spec now, build after M7 client; split gate** (sim 128-bot headless + feel owner-playtest) | Cosmetic layer needs rendering + human validation; sim provable deterministically. Matches M4.5/M7. |
| 2 | Store model | **Fully unify — every piece is chunked; re-gate M4** | One destruction model, one replication path, no second codepath. Re-gate covers regression on M4's closed hot paths (thin tick). |
| 3 | Collapse model | **Support-reachability cascade** (chain-reacting authoritative removals + cosmetic falling), capped, **degrading to whole-building collapse** for large orphans | Delivers "knock out a support → it all comes down" deterministically; tumbling stays client cosmetic; never per-tick physics. |
| 4 | Chunk granularity | **0.25 m, 8×8 = 64 chunks per face, one 64-bit `int` mask**, per-piece-type (props = 1×1) | Brick-ish (not pebbles). Mask is cheap (8 B/piece, one-time baseline + capped deltas). Piece count is the expensive granularity, not chunks. |
| 5 | **A — Bullet immunity** | **Per-type catalog flag**, not global | Building pieces are explosive/melee-only (BattleBit); **player-built sandbag/wall keep bullet vulnerability (M4 preserved)**. One model, behaviour by flag. |
| 6 | **B — Debris/holes tech** | **MultiMesh** for exact hole rendering **+ GPUParticles3D** for flying brick bursts; mesh-swap as far-LOD fallback | Exact any-shape holes from the mask; GPU-cheap, ephemeral, pooled, LOD'd. Never networked. |
| 7 | **C — Sledge/pickaxe** | **Coordinate with M5.5-P3** (melee weapon); M11 owns the **melee→chunk-damage hook** (minimal sledge if P3 hasn't landed) | Avoids duplicating the melee gadget; M11 owns only the wall interaction. |
| 8 | Art authoring | **Fully procedural**, matching M7-P2 art-kit (low-poly, no team-tint) | One pipeline, perfect style match, no licensing; grid-exact pieces + damage states + rubble. |
| 9 | Props | **Non-structural** destructible cover pieces (block movement + weak cover; never load-bearing) | Richer interiors; removed if their floor collapses; don't hold anything up in the cascade graph. |

## Budgets (gate pass/fail)

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), including everything M4
  measured **plus** chunk-mask damage, hole-aware march, support-cascade flood-fill, and chunk/
  collapse delta emission. M4-P2 fleet peak was **29.48 ms** (budget 33.3) and the tick is
  snapshot-dominated — headroom is thin, so M11 must add **no systematic per-tick cost**:
  - Chunk damage and cascade are **event-driven** (explosive/melee events, rare vs. 30 Hz), not
    per-tick. Cascade flood-fill is scoped to one `building_id` and amortizable.
  - Replication reuses M4's `MAX_STRUCTURE_DELTAS_PER_TICK` cap + carry; collapse is **one** event.
  - The only steady-state addition is one **bit test** in the existing ray-march hit.
  - Profile `fire`/`snap`/cascade `[perf]` on the fleet **early** (carry the M4 lesson).
- **Bandwidth:** unchanged budget (≤ ~64 KB/s mean per client; < ~250 Mbit/s aggregate). New
  traffic = `OP_CHUNK` mask deltas (8 B/changed piece, capped) + `COLLAPSE` events (interest-scoped,
  one per building) + baselines carrying the mask (one-time per region entry). Bounded by piece
  count and the per-tick cap; negligible in steady state.
- **Functional gate (Gate A, headless 128-bot):** a 2-team Conquest match on a map **with
  destructible buildings** runs without breaching budget; chunks are **destroyed** (holes appear —
  mask popcount falls), pieces are **removed**, a **cascade fires** (orphaned pieces removed after a
  support is destroyed), at least one **building collapses** (`COLLAPSE` emitted), destruction
  **replicates** (bots observe chunk + remove + collapse deltas), and the **M3 Conquest loop still
  reaches a winner**. **Plus a full M4 re-gate** (building + destruction unchanged after the unify
  refactor).
- **Feel gate (Gate B, owner playtest):** holes/debris/collapse cinematic validated on the rendered
  client (AGENTS.md §10).

---

## Module layout (extends M4)

```
shared/sim/
  chunk_mask.gd       NEW  Pure 64-bit alive-mask helpers: full_mask(grid), bit_index(row,col),
                          clear_in_radius(mask, face_basis, impact, radius) -> mask, popcount,
                          chunk_at(face_uv) -> bit, is_alive(mask, bit). Unit-tested, no engine deps.
  piece_catalog.gd    (mod) per-type: + chunk_grid (1|8), + structural:bool, + damage_types
                          (bitflags BULLET|EXPLOSIVE|MELEE). Validated; server refuses bad catalog.
  structure.gd        (mod) StructureStore: record gains chunks:int (alive-mask) + building_id:int;
                          health derived from popcount. apply_damage replaced by
                          damage_chunks(id, source_type, impact, radius) -> {hit, holed, destroyed,
                          mask}; hole-aware march (skip dead chunk); ids_in_radius reused for blast.
  support.gd          NEW  Support graph over StructureStore: foundation_of(building_id),
                          orphaned_after(removed_ids, building_id) -> Array[id] (flood-fill from
                          foundation; pure). Collapse threshold logic. Unit-tested.
  grenade.gd          (reuse) ballistic + falloff (M4) — detonation now drives damage_chunks.
shared/net/
  protocol.gd         (mod) STRUCTURE_DELTA op set: OP_PLACE(0, full record incl. mask + building_id),
                          OP_REMOVE(1), OP_CHUNK(2){id, mask:u64} (replaces M4 bucket OP_DAMAGE);
                          STRUCTURE_BASELINE record gains mask + building_id; + Msg.COLLAPSE
                          (next free id){building_id:u16}. encode/decode round-tripped.
pieces/
  fortifications.json (mod) player-built: chunk_grid, structural, damage_types incl. BULLET (M4 kept)
  building_kit.json   NEW  building pieces: wall/window/door/floor/stair/column/railing + props;
                          structural flags, damage_types = EXPLOSIVE|MELEE (bullet-immune), chunk_grid.
buildings/
  <name>.json         NEW  prefab = [{type, cell_offset:Vector3i, yaw, structural?}] relative to origin.
maps/
  *.json              (mod) + buildings: [{prefab, origin_cell:Vector3i, yaw}] (each instance gets a
                          unique building_id at server start).
server/server_main.gd (mod) stamp building prefabs into StructureStore at start (assign building_id);
                          explosive/melee → damage_chunks; after damage, run support cascade per
                          touched building (orphan removal or COLLAPSE if > threshold); emit
                          OP_CHUNK / OP_REMOVE / COLLAPSE under MAX_STRUCTURE_DELTAS_PER_TICK;
                          destruction telemetry. Melee strike hook (coordinated with M5.5-P3).
bots/bot_driver.gd    (mod) heuristic: throw frag/RPG at buildings near objectives (reuse M4 heur).
client/                (M7) solid-until-damaged LOD; MultiMesh hole render from mask; GPUParticles
                          brick debris on OP_CHUNK; COLLAPSE cinematic (shake + AudioDirector rumble
                          + smoke zone + sink → procedural rubble swap). All cosmetic, never authoritative.
ci/m11_buildings_test.sh NEW  gate: 128 bots vs destructible buildings; assert holes + removes +
                          cascade + collapse + replicate + budget + winner; + M4 re-gate.
```

---

## A. Chunk model (`shared/sim/chunk_mask.gd`, `structure.gd`)

- A piece's destruction state is a **64-bit alive-mask** (`chunks:int`). For an 8×8 piece, bit
  `row*8 + col` over the piece **face plane** (vertical for walls, horizontal for floors; oriented
  by `yaw`). Born **all-1s**; props are `chunk_grid = 1` (a single bit — degenerate "whole" piece,
  one codepath). A piece is **alive while `chunks != 0`**; `health` = `popcount(chunks)` derived.
- **Damage** = `clear_in_radius(mask, face_basis, impact_point, radius)` clears bits whose chunk
  centres fall within `radius` projected onto the face. Deterministic, pure, unit-tested. Only
  sources allowed by the piece-type `damage_types` clear chunks (Decision A).
- **Removal:** when `chunks == 0`, `store.remove(id)` + free the cell + (if `structural`) trigger a
  support re-evaluation for the piece's `building_id` (§C).
- **Hole-aware march:** in `march`/`_ray_piece`, after the ray-AABB hit, compute the face UV at the
  hit point → chunk bit; if the bit is **dead** (a hole), the ray **passes through** (continue the
  march past this piece). Cost = one bit test added to the existing per-cell hit. Makes holes
  tactically real (shoot/see through them) and keeps cover authoritative.

## B. Damage sources (`server/server_main.gd`)

- **Explosives** (reuse M4 frag + M4.5 RPG): on detonation, `ids_in_radius(P, blast)` → for each
  piece call `damage_chunks(id, EXPLOSIVE, P, falloff_radius)`. Linear falloff already exists
  (`Grenade.falloff_damage` pattern → radius-based chunk clear). Structure + pawn paths unchanged.
- **Melee (sledge/pickaxe)** — coordinated with **M5.5-P3** (Decision C): a melee strike against a
  piece calls `damage_chunks(id, MELEE, hit_point, MELEE_CARVE_RADIUS)` — a small carve per swing
  (sledge wider than pickaxe). M11 owns this hook; if M5.5-P3 hasn't shipped the gadget, M11 adds a
  minimal server-validated melee strike.
- **Bullets:** `damage_types` for building pieces excludes `BULLET` → no chunk change (Decision A).
  Player-built sandbag/wall keep `BULLET` (M4 preserved). M5.5 penetration still passes shots
  through (and now also through holes via §A).

## C. Support & cascade (`shared/sim/support.gd`)

- Every building piece carries `building_id` (loose player-built pieces = 0, never cascade).
  **Foundation** of a building = its pieces with `cell.y == 0` (or a catalog-marked foundation type).
- **On structural piece removal:** `orphaned_after(removed_ids, building_id)` flood-fills
  connectivity (face-adjacency among same-`building_id` pieces; columns connect vertically) from the
  foundation; any building piece **not reachable** is **orphaned**. Orphaned pieces are removed —
  which can orphan more → the function resolves the full fixed point in one pure pass. Scoped to one
  building; bounded by building size; amortizable across ticks if large.
- **Graceful degradation:** if `|orphaned| > COLLAPSE_THRESHOLD`, emit a single
  `COLLAPSE(building_id)` (remove all the building's pieces, mark for rubble swap) **instead of**
  streaming individual removes. Large cascades therefore fall back to the cheapest path
  automatically. Non-structural props are removed when orphaned but never provide support.
- **No separate structural-HP pool:** "big houses take many C4" emerges from needing to destroy
  enough load-bearing pieces (tough columns = high chunk count) to orphan the structure.

## D. Wire protocol (extends `STRUCTURE_DELTA`)

| Msg / op | Dir | Channel/reliability | Body |
|---|---|---|---|
| `STRUCTURE_DELTA OP_PLACE` (0) | S→C | CONTROL, reliable | full record: `id, type, cell i16×3, yaw u8, mask u64, building_id u16, owner u16` |
| `STRUCTURE_DELTA OP_REMOVE` (1) | S→C | CONTROL, reliable | `id u16` |
| `STRUCTURE_DELTA OP_CHUNK` (2) | S→C | CONTROL, reliable | `id u16, mask u64` (replaces M4 bucket `OP_DAMAGE`) |
| `STRUCTURE_BASELINE` | S→C | CONTROL, reliable | region key, `count u16`, then `count` full records (incl. `mask`, `building_id`) |
| `COLLAPSE` (next free id) | S→C | CONTROL, reliable | `building_id u16` |
| `GRENADE_THROW` (12) | C→S | INPUT, unreliable-seq | unchanged (M4) |

All `OP_CHUNK`/`OP_REMOVE`/`COLLAPSE` are emitted **interest-scoped** and under
`MAX_STRUCTURE_DELTAS_PER_TICK` (removes/collapse prioritised over chunk deltas; overflow carried —
M4 §E). Late joiners get exact holes from the baseline `mask`. All encode/decode round-trips
unit-tested.

## E. Client cosmetic layer (M7, never networked)

- **Solid-until-damaged LOD:** a piece with a full mask renders as **one cheap solid mesh** (walls
  look solid when whole — matches BattleBit). On first damage near the viewer it swaps to a
  **`MultiMeshInstance3D` of up-to-64 chunk-cubes** with dead chunks hidden → exact holes. Distant
  pieces stay solid/coarse (far-LOD = pre-authored damage-state mesh swap, Decision B fallback).
- **Brick debris:** on `OP_CHUNK`, spawn a **`GPUParticles3D`** burst of low-poly brick shards at
  the newly-dead chunk locations (ballistic, pooled, ephemeral, LOD'd). Purely local; clients need
  not agree on where shards land.
- **Collapse cinematic:** on `COLLAPSE`, play screen shake + **rumble via the existing
  `AudioDirector`** + a **smoke zone** (reuse M4 smoke VFX) at the building, then **sink + swap** the
  building to its **procedural rubble model** — the sink masked by the smoke. Authoritative state is
  already "pieces gone"; this is dressing on the one event.

## F. Art (fully procedural, M7-P2 style)

Procedural kit generated to match the M7-P2 art-kit (low-poly, no team-tint): `wall`, `window-wall`,
`doorway`, `floor`, `ceiling`, `stair`, `column` (load-bearing), `railing`, plus furniture props
(`table`, `chair`, `bed`, `crate`). Each piece type ships **whole → damaged → destroyed** visual
states (or is rendered via the chunk MultiMesh for exact holes), and each **building prefab** ships
a paired **rubble** model for the post-collapse swap. Stairs/columns require **multi-cell-aware**
authoring (a stair piece spans the height-generic vault/climb path from M4.5).

## G. Authoring (`buildings/*.json`, `maps/*.json`)

- A **building prefab** `buildings/<name>.json` = `{pieces: [{type, cell_offset:Vector3i, yaw,
  structural?}]}` relative to an origin. Hand-authorable/git-diffable like `maps/` and `pieces/`.
- A map references **instances**: `maps/*.json` gains `buildings: [{prefab, origin_cell:Vector3i,
  yaw}]`. The server stamps each instance into `StructureStore` at start, assigning a unique
  `building_id` and placing every piece (reusing the M4 `prebuilt` placement path).
- Prefab + map loaders **validate** (unknown piece type, out-of-bounds cell, overlapping instance)
  and the server **refuses to start** on an invalid prefab/map (mirrors `MapDef`/`PieceCatalog`).

## H. Bot AI (`bots/bot_driver.gd`)

Reuse the M4 explosive heuristic: when alive, near an objective, and line-to-target is blocked by a
structure, off cooldown and under `MAX_BOT_GRENADES`, throw frag/RPG at the blocking building. This
exercises chunk damage + cascade + collapse at objectives under load (Gate A worst case). No new
bot AI required for bullets (they don't damage buildings). Melee wall-breaking by bots is optional
(a drill exerciser may be used to guarantee a melee-carve event at the gate, à la M4.5-P3).

## I. Constants (gate-tuned)

| Const | Value (initial) | Meaning |
|---|---|---|
| `CHUNK_GRID` | 8 | sub-cell chunks per face axis (8×8 = 64; data-driven per piece type) |
| `CHUNK_SIZE` | 0.25 m | chunk edge (`CELL_SIZE / CHUNK_GRID`) |
| `MELEE_CARVE_RADIUS` | ~0.6 m (sledge) / ~0.3 m (pickaxe) | chunk-clear radius per melee swing |
| `COLLAPSE_THRESHOLD` | tuned | orphaned-piece count above which a building collapses as one event |
| `MAX_STRUCTURE_DELTAS_PER_TICK` | 64 (reuse M4) | global per-tick cap on chunk+remove+collapse sends |
| `GRENADE_DAMAGE_STRUCT` | reuse/retune (M4) | explosive chunk-clear strength/radius scaling |

All values gate-tuned in `ci/m11_buildings_test.sh`, exactly like the M4 constants.

---

## J. Testing

**Unit (headless `TestCase`):**
- `chunk_mask`: `full_mask`/`bit_index` round-trip; `clear_in_radius` clears exactly the chunks
  within radius (and none outside), is deterministic, monotonic (bits only clear), idempotent;
  `popcount` damage state; `chunk_at(face_uv)` boundaries.
- `structure.damage_chunks`: respects `damage_types` (bullet no-ops on a building piece; clears on a
  sandbag); removes the piece at `mask == 0`; returns `{hit, holed, destroyed, mask}`.
- **hole-aware march:** a ray through a **dead** chunk passes (no block); through a **live** chunk
  blocks at the right distance; nearest live piece wins; half-height interaction preserved.
- `support.orphaned_after`: removing a foundation/column orphans the dependent pieces (full
  fixed-point in one pass); a self-supported remainder is **not** orphaned; threshold → collapse set.
- **protocol:** `OP_PLACE` (with mask + building_id), `OP_CHUNK`, `OP_REMOVE`, `COLLAPSE`, and
  `STRUCTURE_BASELINE` (with mask) encode/decode round-trip.
- **explosive → chunks:** detonation clears chunks in radius across multiple pieces with falloff,
  FF-off for pawns unchanged; **melee → chunks:** a strike carves the expected chunks.
- **M4 regression:** existing M4 building/destruction unit tests still pass after the unify refactor.

**Integration / gate:** `ci/m11_buildings_test.sh` — server (a map with destructible buildings) +
128 bots, 2 teams; run a match. Assert: holes appear (chunk masks lose bits — surface a count);
pieces **removed**; a **cascade** fires (orphaned removals after a structural kill); ≥1 **building
collapses** (`COLLAPSE` emitted); destruction **replicates** (bots observe chunk + remove + collapse
deltas); **mean/peak tick < 33.3 ms** and **bandwidth held**; **M3 Conquest still reaches a
winner**. **Then re-run the M4 gate** (`docker/run-m4-gate.sh`) to prove player-building/destruction
is unchanged. Run on the `game2` 128-bot fleet (server pinned); ≤48-bot laptop/`game2` smoke first.
Record evidence in the milestone doc. **Gate B:** owner playtest of holes/debris/collapse on the
rendered client.

---

## Data flow — explosive → chunks → cascade → collapse → replicate

```
BOT/CLIENT                                  SERVER (authoritative)
fire/throw frag at building ──GRENADE_THROW▶ validate → spawn server grenade (M4)
                                            detonate at P: ids_in_radius(P, blast)
                                              per piece: damage_chunks(id, EXPLOSIVE, P, r)
apply STRUCTURE_DELTA(OP_CHUNK,mask) ◀──────── chunk bits cleared → mask delta marked
                                              mask==0 → store.remove(id)
                                              if structural: orphaned = support.orphaned_after(...)
apply STRUCTURE_DELTA(OP_REMOVE) ◀──────────── orphaned pieces removed (cascade), under send cap
                                              |orphaned| > COLLAPSE_THRESHOLD →
apply COLLAPSE(building_id) ◀───────────────── remove all building pieces; one event
                                            (client: holes via MultiMesh from mask; brick debris via
                                             GPUParticles; collapse = shake + rumble + smoke + sink →
                                             swap to procedural rubble model — all cosmetic)
```

---

## Out of scope for M11 (explicit)

Per-brick **authoritative** physics (coarse 0.25 m chunk-mask only — forever); **client-divergent**
destruction or **rigid-body tumbling** as gameplay (falling is client cosmetic off authoritative
removals); **terrain/ground** deformation (buildings only, v1); piece **repair** (masks only lose
bits in v1); building **resource/economy**; dynamic player-built **multi-cell** buildings (player
building stays M4 single-cell; map buildings are prefab-authored); **bullets** carving building
walls (immune by `damage_types`). Depends on the **M7 rendered client** (cosmetic layer + Gate B)
and **coordinates with M5.5-P3** (melee sledge/pickaxe gadget). Conquest, movement, gunplay,
vehicles, and player-built fortification *behaviour* are otherwise unchanged (only the underlying
store is unified + re-gated).
