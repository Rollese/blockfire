# Spec: M4 Building (Phase 1 of M4 — Building & Destruction)

**Status:** approved (brainstorm complete; not yet implemented) · **Date:** 2026-06-15 · **Milestone:** [M4](../milestones/M4-building-destruction.md)

BattleBit-style fortification building on top of the M3 Conquest core: server-authoritative placement of snap-to-grid fortification pieces, event-based replication within the interest set, and coarse cover/collision (pieces block bullets and movement). Stays server-authoritative; all rules live in `shared/` so client and server can't diverge (AGENTS.md §5, §7). The gate is **bot-only**: building under 128-bot load must hold the tick + bandwidth budget.

## Phasing

M4 is split into two independently-gated phases:

- **Phase 1 — Building (this spec).** Place/remove pieces, replicate, cover/collision. Pieces carry a `health` field but are **indestructible** in Phase 1 — the fire ray is *blocked* by cover, but applies no damage. Its own 128-bot gate.
- **Phase 2 — Destruction** (`docs/specs/destruction.md`, later). Apply damage to pieces, remove at 0 HP, explosives/area damage, destructible pre-placed environment cover. Sketched in §K; not built here.

Splitting de-risks the highest netcode/physics-cost feature incrementally (M4 risk note), and building gives destruction cheap, bounded things to destroy.

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Placement model | **Snap-to-grid discrete cells** | 2 m cubic cells, 8 yaw steps. Integer-quantized, bounded, delta-friendly, cheap to validate (cell occupancy). BattleBit-ish. |
| Replication | **Event-based + region baseline** | Pieces are static (change only on place/remove). Reliable `STRUCTURE_DELTA` on events + one-time `STRUCTURE_BASELINE` on interest-region entry. **Nothing rides the per-tick snapshot path** — the proven tick hot-spot (M3). |
| Cover/collision | **Block bullets + movement (coarse, grid-aligned)** | Fortifications must be meaningful cover and give destruction a job. Coarse AABB tests reuse the cell occupancy index — bounded cost on the fire/movement paths. |
| Bot building | **Tactical: build cover at objectives** | Bots build near the point they hold/attack → clustered placement + churn at peak interest density. The gate's worst case. |
| Build limits | **Per-player cap + build cooldown** | Max N alive pieces/player (recycle oldest at N+1); cooldown bounds event rate. Deterministic, no resource economy to balance. Caps world pieces at ~128×N. |
| Phase-1 destruction | **Block-only, no damage applied** | Keeps the `_fire_shot` change minimal and isolates destruction's cost into Phase 2's gate. |
| Catalog format | **JSON in `pieces/`** | Mirrors `maps/` (M3): hand-authorable, git-diffable, small tested loader, data separate from code. |

## Budgets (Phase-1 gate pass/fail)

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), including structure ray-march in `_fire_shot`, movement collision, placement validation, and `STRUCTURE_DELTA`/baseline sends.
- Bandwidth unchanged from M1–M3 (≤ ~64 KB/s mean per client; < ~250 Mbit/s aggregate). Structure traffic is event-driven (reliable) + one-time region baselines — bounded by the per-player cap and the interest set; negligible in steady state.
- **Functional gate:** a 128-bot, 2-team match with building enabled runs without breaching budget; pieces **accumulate** (live count grows), structures **replicate** (baselines + deltas observed on bots), and cover **blocks bullets** (demonstrable from telemetry/test). Conquest still progresses to a winner (building must not break the M3 loop).

---

## Module layout (extends M3)

```
shared/sim/
  build_grid.gd      NEW  BuildGrid: cell<->world quantize; 2 m cells, 8 yaw; world-bounds check
  piece_catalog.gd   NEW  PieceCatalog: load_from_json(path); type->{height, health, blocks}; validation
  structure.gd       NEW  StructureRecord + StructureStore: id->record, cell->id occupancy,
                          region->{ids} index; place/remove/recycle; ray-march (DDA); cell-block query
shared/net/
  protocol.gd        (mod) + Msg.BUILD_REQUEST, BUILD_REMOVE, STRUCTURE_DELTA, STRUCTURE_BASELINE
  quantize.gd        (mod) helpers for cell i16 / yaw u8 if needed
pieces/
  fortifications.json NEW  v1 catalog: sandbag (half), wall (full)
server/server_main.gd  (mod) load catalog; handle build req/remove + validate; structure store;
                              ray-march in _fire_shot (block); movement collision; per-client known
                              regions + baseline on region entry; STRUCTURE_DELTA on events; telemetry
bots/bot_driver.gd     (mod) tactical build heuristic at objective (cooldown/cap aware)
ci/m4_building_test.sh NEW  gate: 128 bots build under load; assert accumulate + replicate + budget
```

---

## A. Build grid (`shared/sim/build_grid.gd`)

- **Cells:** 2 m cubes. `cell_of(world: Vector3) -> Vector3i` (floor-divide by `CELL_SIZE`); `world_of(cell: Vector3i) -> Vector3` (cell center, `y = cy * CELL_SIZE`). Coords are `i16` on the wire (`world_half=1000` → ±500 cells; fits with margin).
- **Yaw:** 8 discrete steps (45°), `0..7`, stored `u8`. `yaw_radians(step) -> float`.
- **Bounds:** `in_bounds(cell)` rejects cells outside the map's `world_half`. `cy >= 0` (ground and above; no underground).
- Pure functions, fully unit-tested (quantize round-trip, bounds).

## B. Piece catalog (`shared/sim/piece_catalog.gd`, `pieces/fortifications.json`)

```json
{
  "pieces": [
    {"id": "sandbag", "height": "half", "health": 150, "blocks": "both"},
    {"id": "wall",    "height": "full", "health": 350, "blocks": "both"}
  ]
}
```

- `PieceCatalog.load_from_json(path)` parses + **validates**: `pieces` non-empty; each has a non-empty unique `id`, `height ∈ {half, full}`, `health > 0`, `blocks ∈ {both}` (v1; reserved for future cover variants). On error returns an error result (tested); server refuses to start on an invalid catalog.
- Types are indexed `0..N-1` in array order; the index is the `u8` `type` on the wire. `id` is a display label.
- `height`: `full` = full 2 m cell AABB; `half` = lower 1 m of the cell (blocks crouched/low; a standing shot can pass above). Both block movement (treated as a solid cell for pawns in v1).

## C. Structure store (`shared/sim/structure.gd`)

`StructureRecord`: `{id u16, type u8, cell Vector3i, yaw u8, health u16, owner u16}`.

`StructureStore` (server-side authority; clients hold a read-only mirror built from deltas/baselines):
- `_by_id: Dictionary` (id → record), `_occupancy: Dictionary` (cell → id), `_by_region: Dictionary` (region key → `{ids}`), `_by_owner: Dictionary` (owner → ordered ids, for cap-recycle).
- `place(rec) -> bool` — fails if cell occupied; else inserts into all four indexes. `remove(id)` — frees cell, drops from indexes.
- `recycle_oldest(owner)` — removes the owner's oldest piece (FIFO) to make room at the cap.
- **Region key:** the existing interest-grid cell containing `world_of(cell)` (reuse `InterestGrid`'s cell math) so structure regions align with the per-client interest set.
- **Ray-march** `march(origin, dir, max_dist) -> {hit: bool, dist: float, id}`: DDA-walk the build grid from `origin` along `dir` up to `max_dist`; at each occupied cell, test the piece AABB (height-aware: `full` = whole cell, `half` = lower 1 m). Return the nearest blocking hit. Bounded by `max_dist / CELL_SIZE` cells.
- **Movement query** `blocks_cell(cell) -> bool`: O(1) occupancy + type-blocks lookup.

All store ops are pure data over the indexes — fully unit-testable without a server.

---

## D. Placement & validation (server-authoritative)

Client→server **`BUILD_REQUEST {type u8, cell i16×3, yaw u8}`** (INPUT channel, unreliable-sequenced — a dropped request is simply retried next cooldown). Server validates, in order — any failure → silent reject (bots retry later; no client-trusted geometry, server owns all cell math):

1. Player **alive**.
2. **Off cooldown:** `now_tick - last_build_tick[client] >= BUILD_COOLDOWN_TICKS` (150 = 5 s).
3. **Range:** `world_of(cell)` within `BUILD_RANGE` (≈ 5 m) of the player, roughly in front (planar).
4. **Bounds:** `BuildGrid.in_bounds(cell)`.
5. **Unoccupied:** `cell ∉ _occupancy`.
6. **Support:** `cy == 0` (ground) **or** the cell directly below (`cy-1`) is occupied.
7. **Cap:** if owner already at `MAX_PIECES_PER_PLAYER` (12), `recycle_oldest(owner)` (emits a remove delta) before placing.

On success: assign `id` (monotonic `u16`), `health` from catalog, `store.place(rec)`, set `last_build_tick[client]`, emit `STRUCTURE_DELTA(place)`.

**`BUILD_REMOVE {id u16}`** — removes a piece the client owns (also the internal cap-recycle path). Emits `STRUCTURE_DELTA(remove)`.

**Constants (gate-tuned in `ci/m4_building_test.sh`):**

| Const | Value | Meaning |
|---|---|---|
| `CELL_SIZE` | 2.0 m | build grid cell edge |
| `YAW_STEPS` | 8 | discrete orientations (45°) |
| `MAX_PIECES_PER_PLAYER` | 12 | per-player alive-piece cap (recycle oldest at N+1) |
| `BUILD_COOLDOWN_TICKS` | 150 | ticks between placements (5 s @ 30 Hz) |
| `BUILD_RANGE` | 5.0 m | max placement distance from the player |

---

## E. Replication (event-based + region baseline)

**`STRUCTURE_DELTA`** (server→client, **reliable**, CONTROL channel): `op u8 (0=place, 1=remove)`; `id u16`; for `place` the full record (`type u8, cell i16×3, yaw u8, health u16, owner u16`). Sent immediately on the event **to each client whose current interest set includes the cell's region**. (Clients without the region will receive it via baseline if/when they enter.)

**`STRUCTURE_BASELINE`** (server→client, **reliable**): `region key`, `count u16`, then `count` records. Sent **once** when a client's interest set first gains a region that contains structures. Server tracks `known_regions[client]: {region keys}`; each tick, for regions newly added to the client's interest set (already computed for snapshots), send a baseline and mark known. Regions dropping out of the interest set are forgotten (re-baselined on re-entry) to bound per-client memory.

**No per-tick cost for static pieces** — structures never enter the pawn snapshot/relevance path. Steady-state structure bandwidth is event-driven + bounded by the per-player cap; baselines are one-time per region entry.

---

## F. Wire protocol changes

New messages (no changes to existing `SNAPSHOT`/`INPUT`/`MATCH_STATE` bodies):

| Msg | Dir | Channel/reliability | Body |
|---|---|---|---|
| `BUILD_REQUEST` | C→S | INPUT, unreliable-seq | `type u8, cx i16, cy i16, cz i16, yaw u8` |
| `BUILD_REMOVE` | C→S | CONTROL, reliable | `id u16` |
| `STRUCTURE_DELTA` | S→C | CONTROL, reliable | `op u8, id u16, [place: type u8, cx/cy/cz i16, yaw u8, health u16, owner u16]` |
| `STRUCTURE_BASELINE` | S→C | CONTROL, reliable | `region_key (u32 or as InterestGrid encodes), count u16, count×{type u8, id u16, cx/cy/cz i16, yaw u8, health u16, owner u16}` |

All encode/decode round-trips are unit-tested.

---

## G. Sim integration (`server/server_main.gd`)

- **Fire ray (`_fire_shot`):** after gathering the rewound enemy candidates (M3 grid pre-filter), call `store.march(shot_origin, shot_dir, weapon.range_m)`. If a blocking piece is hit at `dist_struct` and the nearest enemy hit is at `dist_enemy`, the shot **lands on the enemy only if `dist_enemy < dist_struct`**; otherwise it is blocked by cover (Phase 1: no damage to the piece). Half-height `sandbag` only blocks rays passing through its lower 1 m. Cost is bounded by `range / CELL_SIZE` cell steps with O(1) occupancy lookups.
- **Movement collision:** in the movement step, a pawn cannot enter a cell where `store.blocks_cell(cell)` — kinematic stop/slide against the cell face (coarse; reuses `Pawn`'s existing kinematic resolution). No ramp-climbing in v1.
- **Build handling:** poll → `BUILD_REQUEST`/`BUILD_REMOVE` validated (§D) → `STRUCTURE_DELTA` emitted. Placement is resolved in the tick it arrives, before snapshots.
- **Baselines:** during the per-client interest pass (already computed for snapshots), diff `known_regions[client]` against the new interest set and emit `STRUCTURE_BASELINE` for newly-entered structured regions.

Updated `_physics_process` order:
```
poll (incl. BUILD_REQUEST/REMOVE → validate → STRUCTURE_DELTA)
  → _step_movement (now structure-collision aware)
  → _lag.record → (build interest grid)
  → _resolve_fires (now structure-ray-march blocks shots)
  → _handle_respawns (_select_spawn)
  → _conquest.step
  → _send_snapshots (+ per-client STRUCTURE_BASELINE on region entry)
  → _maybe_broadcast_match_state
  → telemetry
```

---

## H. Bot AI (`bots/bot_driver.gd`)

In addition to the M3 objective/combat AI:
1. When the bot is **alive, near/inside its objective radius, and roughly stationary** (holding/defending, not actively chasing an enemy), and is **off build cooldown** and **under cap**, it issues a `BUILD_REQUEST`.
2. **Where:** the cell ~one step toward the enemy-facing direction (from match-state: toward the nearest enemy-owned point, or the last-seen enemy), at `cy=0`, snapped via `BuildGrid`. Pick `yaw` facing the threat. Hysteresis so it doesn't spam invalid cells.
3. Bots don't need `BUILD_REMOVE` for the gate (cap-recycle is server-side).

This produces clustered placement + churn at objectives — the peak-interest worst case the gate must hold.

---

## I. Telemetry additions

Extend the per-second log with: `struct` (live piece count), `bld` (placements this window), `rmv` (removals incl. recycles). Add `[perf]` lines for **structure ray-march**, **movement collision**, and **baseline-send** cost, alongside the existing per-phase perf telemetry (re-profile on the fleet early — HANDOVER warns M4 adds cost on top of the tuned `_send_snapshots`). Existing M2/M3 counters stay.

---

## J. Testing

**Unit (headless `TestCase`):**
- `build_grid`: cell↔world quantize round-trip; yaw step→radians; bounds rejection; `cy<0` rejected.
- `piece_catalog`: loads v1 JSON; validation rejects empty pieces, duplicate/empty `id`, bad `height`, `health<=0`.
- `structure` store: place/remove updates all indexes; double-place on occupied cell fails; `recycle_oldest` is FIFO; region index keys match `InterestGrid` cells.
- `structure` ray-march (DDA): ray through an occupied cell hits at the right distance; empty path misses; **half-height** blocks a low ray but not a high one; nearest of two pieces wins.
- movement: `blocks_cell` true for occupied blocking cell; pawn cannot enter it.
- placement validation: cooldown gate, cap + recycle, occupancy, support (ground vs piece-below), range, bounds — each rejected/accepted as specified.
- protocol: `BUILD_REQUEST`, `BUILD_REMOVE`, `STRUCTURE_DELTA` (place + remove), `STRUCTURE_BASELINE` encode/decode round-trip.
- bot heuristic: emits a valid `BUILD_REQUEST` (in range, in bounds) only when alive/stationary/off-cooldown/under-cap.

**Integration / gate:** `ci/m4_building_test.sh` — server (v1 map + catalog) + 128 bots, 2 teams, building enabled; run a match. Assert: live piece count **grows** (bots build); structures **replicate** (bots observe baselines + deltas — surface a bot-side structure count); cover **blocks shots** (a hit-rate / blocked-shot counter shows blocking occurs); **mean/peak tick < 33.3 ms** and **bandwidth budget held**; and the **M3 Conquest loop still reaches a winner**. Run on the unraid W-2275 fleet (`docker/`, server pinned); 48-bot laptop smoke first. Record evidence in the milestone doc.

---

## Data flow — place + cover + replicate

```
BOT/CLIENT                                   SERVER (authoritative)
hold objective, off-cooldown ──BUILD_REQUEST▶ validate (alive/cooldown/range/bounds/
                                               occupied/support/cap→recycle)
                                              store.place(rec); set last_build_tick
apply STRUCTURE_DELTA(place) ◀──────────────── emit to clients whose interest set has the region
enter new area ── interest set gains region ─▶ diff known_regions → emit STRUCTURE_BASELINE(region)
apply STRUCTURE_BASELINE ◀──────────────────── (one-time per region entry)
fire at enemy behind cover ───shot input────▶ _resolve_fires: store.march(...) blocks the ray
                                               (Phase 1: no damage to piece) → no enemy hit
cap reached, place again ─────BUILD_REQUEST─▶ recycle_oldest(owner) → STRUCTURE_DELTA(remove)
                                               then place new → STRUCTURE_DELTA(place)
```

---

## K. Phase 2 (Destruction) — sketch only, NOT built in this spec

For continuity (separate spec `docs/specs/destruction.md` + its own gate later):
- Fire ray applies `weapon` damage to the blocking piece instead of just blocking; `health<=0` → `store.remove(id)` + `STRUCTURE_DELTA(remove)` + free cell.
- Explosives/area damage decrement multiple cells in a radius.
- Destructible **pre-placed environment cover** reuses the same coarse cell-health model (authored in the map/catalog with `start_health`).
- **Graceful degradation** (M4 risk note): if the tick budget is threatened, cap damage events per window and coarsen the damage model (no per-fragment physics). Define the fallback before implementing.

---

## Out of scope for M4 Phase 1 (explicit)

Any destruction/damage to pieces (Phase 2); destructible environment/terrain (Phase 2); build resource/supply economy (rejected for this gate); free/continuous placement and socket-snap (rejected — grid only); ramp-climbing movement; client build UI / placement preview (M7, with rendering — Phase 1 ships the data a build UI needs); piece rotation beyond 8 yaw steps; multi-cell footprints (v1 pieces are 1 cell); art/meshes (M7). Conquest, movement, and gunplay are otherwise unchanged from M3.
