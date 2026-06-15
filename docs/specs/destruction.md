# Spec: M4 Destruction (Phase 2 of M4 — Building & Destruction)

**Status:** approved (brainstorm complete; not yet implemented) · **Date:** 2026-06-15 · **Milestone:** [M4](../milestones/M4-building-destruction.md)

Phase 2 makes Phase-1 fortifications **destructible** and adds **explosives** (area damage to
structures *and* pawns). Built directly on the Phase-1 substrate (`BuildGrid`, `PieceCatalog`,
`StructureStore`, `STRUCTURE_DELTA/BASELINE`, the server fire-ray `march`): pieces already carry
`health`, and Phase 1 *blocked* the fire ray. Phase 2 makes that health matter. Stays
server-authoritative; all rules live in `shared/` so client and server can't diverge (AGENTS.md
§5, §7). The gate is **bot-only**: building **and** destruction under 128-bot load must hold the
tick + bandwidth budget. This is M4's highest-cost feature — graceful degradation is defined here
**before** implementation (M4 risk note).

> Phase 1 (Building) is the companion spec `docs/specs/building.md`; read it first. This spec only
> adds the destruction layer and does not change any Phase-1 decision.

## Scope (ratified in brainstorm, 2026-06-15)

| In scope (this gate) | Deferred |
|---|---|
| **Bullet damage** to pieces (fire ray damages the blocking piece; remove at 0 HP) | Destructible **pre-placed environment cover** (later; reuses this cell-health model with `start_health` in the map/catalog) |
| **Explosives (frag)**: thrown, server-side, area damage to **structures + pawns** | Grenade **in-flight replication** / client VFX (M7, with rendering) |
| **Smoke grenades**: thrown, server-side, spawn smoke zone entity (position + duration); no damage; client VFX deferred to M7 | Smoke **LOS culling** integration (M7, anti-wallhack extension — server zone data already present) |
| **Throttled HP-bucket** damage replication (75/50/25 %) | Per-fragment / voxel-shatter physics (coarse cell-health only, forever) |
| **Graceful degradation** fallback (delta-send throttling) | Explosive **self-damage** balancing (FF-off incl. self in v1; tunable later) |
| Bot AI: throw frag explosives at cover/enemy clusters; throw smoke to obscure a rush | Resource/supply economy for explosives (rejected, as for building) |

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Bullet → piece | **Fire ray applies `weapon.damage_body` to the blocking piece** | Reuses the Phase-1 `march` hit at zero new bot AI: bots already fire through cover at enemies (Phase-1 `blocked_shots`); those shots now chew the wall down. Steady-state destruction load. |
| Partial-HP replication | **Throttled HP buckets** (`75/50/25 %`), ≤1 delta/piece/tick | Each piece emits **≤3 damage deltas + 1 remove** over its whole life regardless of bullet count — bounds the new reliable traffic by piece count, not hit count. Gives the M7 client damage state now. |
| Explosive model | **Server-side grenade, off the snapshot path** | Throw via input; server simulates fuse + arc; detonates at **server-present time**. The grenade never enters the bounded per-tick pawn snapshot path (same discipline that kept Phase-1 structures off the M3 hot path). |
| Explosive lag-comp | **None — present-time positions** | A thrown grenade detonates after travel/fuse, so area damage resolves against *current* pawn positions at the detonation tick. Distinct from hit-scan (which rewinds to the shooter's `view_server_tick`); simpler and correct for delayed detonation. |
| Explosive targets | **Structures (cell radius) + pawns (sphere radius)** | Full BattleBit explosive. Pawn splash is a second attrition vector; structure splash is the multi-cell destruction path the gate must hold. |
| Friendly fire | **Off (incl. self) in v1** | Consistent with M2/M3 (FF off). No team/self splash. Tunable knob; self-damage balance deferred. |
| Graceful degradation | **Throttle delta *sends*, never the authoritative state** | Server always applies damage/removal (state stays correct + converges); only the per-tick `STRUCTURE_DELTA` send count is capped (`MAX_STRUCTURE_DELTAS_PER_TICK`), excess carried to next tick. Blast removes are implicitly bounded by `BLAST_CELL_RADIUS`. |

## Budgets (Phase-2 gate pass/fail)

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), including everything Phase 1
  measured **plus** bullet damage application, blast resolution (cell + pawn radius queries), and
  bucket/remove delta emission. Phase 1 already pushed the fleet peak to **30.89 ms** (M3 was 28.6);
  destruction's headroom is thin — profile `fire`/`snap`/blast `[perf]` on the fleet **early**.
- **Bandwidth** unchanged from M1–M4 Phase 1 (≤ ~64 KB/s mean per client; < ~250 Mbit/s aggregate).
  New structure traffic is the bucket-damage + remove deltas — event-driven, reliable, bounded by
  the bucket model and the per-tick send cap; negligible in steady state.
- **Functional gate:** a 128-bot, 2-team match with **building and destruction enabled** runs
  without breaching budget; pieces are **destroyed** (live count falls after bullet/blast damage —
  `destroyed` grows), explosives **detonate** (`nades > 0`) and produce **splash kills**, damage
  **replicates** (bucket + remove deltas observed on bots), and the M3 Conquest loop **still reaches
  a winner** (destruction must not break the loop).

---

## Module layout (extends M4 Phase 1)

```
shared/sim/
  structure.gd       (mod) StructureStore: + apply_damage(id, amount) -> {destroyed, health, bucket,
                          crossed}; + bucket_of(health, max) -> int; + cells_in_radius(center_cell,
                          r) -> Array[Vector3i] (occupied cells only). All pure data ops.
  grenade.gd         NEW  Grenade record + pure helpers: fuse/step trajectory; blast_cells(center,
                          radius) and falloff_damage(center, point, max_dmg, radius) -> int.
                          Grenade has a `type` field: FRAG (area damage) or SMOKE (spawn zone, no
                          damage). Throw/arc/fuse logic is identical for both types.
shared/net/
  protocol.gd        (mod) + Msg.GRENADE_THROW; + OP_DAMAGE; STRUCTURE_DELTA carries {id, bucket}
                          for OP_DAMAGE; (Msg.DETONATION reserved, NOT sent in the gate)
  quantize.gd        (reuse) i16 cell / dir packing as Phase 1
pieces/
  fortifications.json (reuse) per-type `health` already authored (Phase 1)
server/server_main.gd  (mod) bullet damage in _fire_shot; grenade poll → spawn → fuse → detonate
                              (frag: structure + pawn area damage, FF-off, present-time;
                               smoke: spawn _smoke_zones entry, broadcast SMOKE_DEPLOYED);
                              bucket-diff emission after fire+blast; MAX_STRUCTURE_DELTAS_PER_TICK
                              send cap; telemetry (dmg/destroyed/nades/splash_kills + blast [perf])
bots/bot_driver.gd     (mod) grenade heuristic: throw at cover/enemy when blocked, cooldown + cap
ci/m4_destruction_test.sh NEW  gate: 128 bots build + destroy under load; assert destroyed +
                              nades + splash + replicate + budget + winner
```

---

## A. Bullet damage (`server/server_main.gd::_fire_shot`, `StructureStore.apply_damage`)

Phase 1 ends `_fire_shot` by treating a nearer blocking piece as "shot blocked, no enemy hit".
Phase 2 replaces *blocked* with *damaged*:

1. `march(shot_origin, shot_dir, weapon.range_m)` → `{hit, dist, id}` (unchanged Phase-1 call).
2. If a blocking piece is nearer than the nearest rewound enemy hit (`dist_struct < dist_enemy`),
   call `store.apply_damage(id, weapon.damage_body)`:
   - decrement `rec["health"]` by `amount` (floor at 0);
   - if `health <= 0`: `store.remove(id)`, free the cell, mark for an **`OP_REMOVE`** delta;
   - else compute the new bucket; if it **crossed** to a lower bucket, mark for an **`OP_DAMAGE`**
     delta (see §C). Return `{destroyed, health, bucket, crossed}`.
3. The shot is consumed by the piece (no enemy hit), exactly as Phase 1 — only the side effect on
   the piece is new. Half-height pieces still only intercept rays through their lower 1 m (Phase-1
   `_ray_piece`).

`apply_damage` is pure data over the store indexes — fully unit-testable without a server. Cost is
the Phase-1 `march` (unchanged) plus O(1) health math.

## B. Explosives (`shared/sim/grenade.gd`, server)

**Throw.** Client→server **`GRENADE_THROW {dir (quantized), aim/charge?}`** (INPUT channel,
unreliable-sequenced — a dropped throw is retried next cooldown). Server validates, in order; any
failure → silent reject (no client-trusted geometry; server owns all blast math):

1. Player **alive**.
2. **Off cooldown:** `now_tick - last_grenade_tick[client] >= GRENADE_COOLDOWN_TICKS`.
3. (Optional v1 ammo cap: `grenades_remaining[client] > 0`; decrement on throw.)

On success the server creates a **server-side grenade** (NOT a replicated snapshot entity):
`{owner, team, origin, vel, fuse_tick = now + GRENADE_FUSE_TICKS}`. Each tick, integrate a simple
ballistic arc (`grenade.gd` pure `step`); on `now_tick >= fuse_tick` (or ground/structure contact,
v1 = fuse only) **detonate** at the grenade's current position `P`:

- **Structures:** for each occupied cell in `store.cells_in_radius(cell_of(P), BLAST_CELL_RADIUS)`,
  apply `falloff_damage(P, cell_center, GRENADE_DAMAGE_STRUCT, blast_radius_m)` via
  `store.apply_damage` (§A path: removes / bucket deltas, subject to the §E send cap).
- **Pawns:** for each pawn within `BLAST_RADIUS` of `P` (sphere, **current** positions — no rewind),
  apply `falloff_damage(P, pawn_pos, GRENADE_DAMAGE_PAWN, BLAST_RADIUS)`, **skipping same-team and
  the thrower** (FF-off incl. self). Deaths route through the existing death/`KILL`/respawn path
  (killer = grenade owner, `headshot=false`); count `splash_kills`.

`blast_cells` and `falloff_damage` are pure functions (linear falloff, 0 at the radius edge),
unit-tested independently of the server. A **`Msg.DETONATION`** event (position + radius) is
**reserved** for M7 client VFX but **not sent** in this gate (off the snapshot path; nothing new
rides per-tick replication).

## B.5 Smoke grenades

`Grenade` gains a `type` field (`FRAG` / `SMOKE`). The throw path (§B), cooldown gating, arc integration, and fuse/contact detonation logic are **identical** for both types. Only the detonation side effect differs.

On smoke detonation the server:
1. Does **not** apply any damage.
2. Creates a **server-side smoke zone** `{pos, radius=SMOKE_RADIUS, expire_tick = now + SMOKE_DURATION_TICKS}` in `_smoke_zones: Array`.
3. Broadcasts a **`SMOKE_DEPLOYED`** event (reliable CONTROL) to interested clients — the full zone record at detonation time. No per-tick update; clients know the zone by position, radius, and `expire_tick`.
4. Cleans up expired zones each tick (O(zones), negligible).

Smoke zones are also consumed in M7 for server-side LOS culling (anti-wallhack extension): when a pawn is inside a smoke zone the server may withhold enemy snapshot state from clients without LOS through the smoke — the zone data is already present from this milestone.

**No damage path is called on smoke detonation.** Smoke is FF-neutral (there is no harm to block).

Bot AI: throw smoke to obscure a rush route at an objective or to cover a DBNO revive attempt (M4.5 context). Smoke throw uses the same `last_grenade_tick` cooldown as frags (one shared throw cooldown per player; only one grenade type thrown per class per cooldown window).

**Constants:**

| Const | Value | Meaning |
|---|---|---|
| `SMOKE_DURATION_TICKS` | 150 (5 s) | smoke zone lifetime |
| `SMOKE_RADIUS` | 6.0 m | smoke zone radius (matches blast radius for consistency) |

---

## C. Throttled HP-bucket replication

Pieces have 4 visible states by remaining-health fraction `f = health / max_health`:

| bucket | fraction | meaning |
|---|---|---|
| 3 | `f > 0.75` | pristine (the place/baseline state) |
| 2 | `0.50 < f ≤ 0.75` | lightly damaged |
| 1 | `0.25 < f ≤ 0.50` | damaged |
| 0 | `0 < f ≤ 0.25` | heavily damaged |
| — | `f ≤ 0` | destroyed → `OP_REMOVE` (not a damage delta) |

`bucket_of(health, max)` maps to `0..3`. The server keeps the last-sent bucket per piece (a piece
is born at bucket 3 from its place/baseline). After **all** fire + blast damage for the tick is
applied, it diffs each touched piece's current bucket against last-sent and emits **one**
`STRUCTURE_DELTA(OP_DAMAGE){id, bucket}` per piece whose bucket dropped (coalescing multiple
crossings in one tick into a single delta carrying the lowest bucket reached). Sent **reliably** on
CONTROL to clients whose interest set holds the piece's region (same rule as `OP_PLACE`/`OP_REMOVE`).

Region **baselines** already carry the full `health` (Phase-1 `_put_record`), so a client entering a
region late gets exact current health and derives the bucket locally — no replay of past damage
deltas needed. Buckets only ever decrease (no repair in v1).

## D. Wire protocol changes

New message + one new `STRUCTURE_DELTA` op (no changes to existing bodies):

| Msg / op | Dir | Channel/reliability | Body |
|---|---|---|---|
| `GRENADE_THROW` (12) | C→S | INPUT, unreliable-seq | `dir (quantized i16×3 or yaw/pitch), type u8 (0=FRAG 1=SMOKE), [charge u8]` |
| `STRUCTURE_DELTA OP_DAMAGE` (op=2) | S→C | CONTROL, reliable | `op u8 (=2), id u16, bucket u8` |
| `DETONATION` (13) | S→C | *reserved, not sent in gate* | `pos i16×3, radius u8` (M7 VFX) |
| `SMOKE_DEPLOYED` (14) | S→C | CONTROL, reliable | `pos i16×3, radius u8, expire_tick u16` |

`encode_structure_delta`/`decode_structure_delta` extend their existing op switch: `OP_PLACE` →
full record (Phase 1), `OP_REMOVE` → `id` (Phase 1), `OP_DAMAGE` → `id, bucket` (new). All
encode/decode round-trips unit-tested.

## E. Graceful degradation (the M4 risk-note fallback)

**Authoritative state is never throttled.** All damage and removals are applied on the server every
tick so the simulation stays correct and converges. Only the **delta send volume** is bounded:

- `MAX_STRUCTURE_DELTAS_PER_TICK` caps the combined `OP_DAMAGE` + `OP_REMOVE` deltas emitted per
  tick (global). If a tick generates more (e.g. a grenade flattens a cluster), the excess is
  **carried into the next tick's send budget** (a pending-delta queue per client/region). Removes
  take priority over damage (a piece that's gone matters more than a bucket change). Clients
  converge at most a few ticks late; a region re-baseline (Phase-1 path) is the backstop.
- Blast cost is additionally bounded by `BLAST_CELL_RADIUS` (small cell neighborhood) and
  `GRENADE_COOLDOWN_TICKS` + per-bot `MAX_BOT_GRENADES` (the throw rate).
- All values are gate-tuned in `ci/m4_destruction_test.sh`, exactly like the Phase-1 constants.

**Constants (gate-tuned):**

| Const | Value (initial) | Meaning |
|---|---|---|
| `DAMAGE_BUCKETS` | `[0.75, 0.50, 0.25]` | bucket thresholds (fraction of max health) |
| `GRENADE_FUSE_TICKS` | 45 (1.5 s) | ticks from throw to detonation |
| `GRENADE_COOLDOWN_TICKS` | 300 (10 s) | min ticks between a player's throws |
| `BLAST_RADIUS` | 6.0 m | pawn splash radius (sphere) |
| `BLAST_CELL_RADIUS` | 2 cells (~4 m) | structure splash radius (build cells) |
| `GRENADE_DAMAGE_PAWN` | 100 (center) | pawn splash at center, linear falloff to 0 at edge |
| `GRENADE_DAMAGE_STRUCT` | 200 (center) | structure splash at center, linear falloff |
| `MAX_STRUCTURE_DELTAS_PER_TICK` | 64 | global per-tick cap on damage+remove sends (degradation) |
| `MAX_BOT_GRENADES` | 1 | per-bot lifetime throw cap (convergence/over-destruction knob) |

---

## F. Sim integration (`server/server_main.gd`)

Updated `_physics_process` order (Phase-1 order + the **bold** destruction steps):

```
poll (incl. BUILD_REQUEST/REMOVE → validate → STRUCTURE_DELTA; GRENADE_THROW → validate → spawn grenade)
  → _step_movement (structure-collision aware, Phase 1)
  → _lag.record → (build interest grid)
  → _resolve_fires (structure ray-march now APPLIES damage → removes / bucket marks)
  → **_step_grenades** (integrate arcs; detonate fused → structure + pawn area damage)
  → _handle_respawns (incl. splash deaths)
  → _conquest.step
  → **_emit_structure_deltas** (diff touched pieces' buckets; flush damage+remove deltas under
       MAX_STRUCTURE_DELTAS_PER_TICK; carry overflow)
  → _send_snapshots (+ per-client STRUCTURE_BASELINE on region entry, Phase 1)
  → _maybe_broadcast_match_state
  → telemetry
```

Bucket-delta emission is centralized in `_emit_structure_deltas` (after fire **and** grenades) so
multiple damage sources on one piece in one tick coalesce to a single delta.

## G. Bot AI (`bots/bot_driver.gd`)

Bullet destruction needs **no** new AI — bots already fire through cover at enemies (Phase-1
`blocked_shots`); those shots now destroy the wall. Add an explosive heuristic mirroring the
Phase-1 build heuristic:

1. When the bot is **alive**, near its objective, its line to the target enemy is **blocked by a
   structure** (it can detect this from its local structure mirror / repeated blocked fire), **off
   `GRENADE_COOLDOWN`**, and **under `MAX_BOT_GRENADES`** → issue `GRENADE_THROW` aimed at the
   blocking cover / enemy cluster.
2. Hysteresis so it doesn't spam at an invalid/aimless direction.

This produces clustered destruction churn at objectives — the gate's worst case (a grenade landing
in a built-up point is the multi-cell-remove + splash-kill burst that exercises §E). `MAX_BOT_GRENADES`
is the convergence/over-destruction tuning knob (mirrors `MAX_BOT_BUILDS`); lower it if a fleet match
over-destroys into a no-cover stalemate or over-kills via splash.

## H. Telemetry additions

Extend the per-second log with: `dmg` (damage events applied this window), `destroyed` (pieces
removed by damage/blast this window), `nades` (detonations this window), `splash_kills` (pawn
deaths from blasts). Add `[perf]` lines for **bullet damage application**, **blast resolution**
(cell + pawn radius), and **delta-flush** cost, alongside the existing Phase-1/M3 per-phase perf.
Re-profile `fire`/`snap` on the fleet early — destruction stacks on the already-thin 30.89 ms peak.
Existing M2/M3/M4-P1 counters stay.

---

## I. Testing

**Unit (headless `TestCase`):**
- `structure.apply_damage`: reduces health; `health<=0` removes the piece + frees the cell + drops
  it from all indexes; returns `destroyed=true`. Non-lethal damage returns the new health/bucket.
- `structure.bucket_of`: maps health fractions to `0..3` at the 75/50/25 boundaries (edge cases on
  each threshold); a born piece is bucket 3.
- **bucket coalescing:** several hits in one logical step that cross multiple thresholds yield a
  single emitted delta carrying the **lowest** bucket; no delta when the bucket is unchanged.
- `grenade.blast_cells` / `cells_in_radius`: returns exactly the occupied cells within the radius
  (and none outside); `falloff_damage` is max at center, 0 at the edge, linear between, never
  negative.
- **pawn splash:** damages enemies in radius with falloff; **skips same-team and the thrower**
  (FF-off); uses present-time positions (no rewind); lethal splash routes a `KILL` + respawn.
- **protocol:** `GRENADE_THROW` and `STRUCTURE_DELTA(OP_DAMAGE)` encode/decode round-trip; the
  three-op `STRUCTURE_DELTA` switch (place/remove/damage) all round-trip.
- **degradation:** when a tick generates more than `MAX_STRUCTURE_DELTAS_PER_TICK`, removes are
  prioritized and the overflow is carried (state already applied; no delta lost, just deferred).
- **bot heuristic:** emits a valid `GRENADE_THROW` only when alive/blocked/off-cooldown/under-cap.

**Integration / gate:** `ci/m4_destruction_test.sh` — server (v1 map + catalog) + 128 bots, 2 teams,
**building and destruction enabled**; run a match. Assert: pieces are **destroyed** (`destroyed`
grows; live `struct` count falls after damage); explosives **detonate** (`nades > 0`) and produce
**splash kills**; damage **replicates** (bots observe bucket + remove deltas — surface a bot-side
count); **mean/peak tick < 33.3 ms** and **bandwidth budget held**; and the **M3 Conquest loop
still reaches a winner**. Run on the unraid W-2275 fleet (`docker/`, server pinned to isolated
cores); 48-bot laptop smoke first. Add the M4-P2 assertions to a `docker/run-m4-gate.sh` variant
(or extend it) the same way Phase 1 did. Record evidence in the milestone doc.

---

## Data flow — bullet + blast + replicate

```
BOT/CLIENT                                     SERVER (authoritative)
fire at enemy behind cover ──shot input──────▶ _resolve_fires: march hits piece nearer than enemy
                                                store.apply_damage(id, weapon.damage_body)
apply STRUCTURE_DELTA(damage,bucket) ◀───────── bucket dropped → mark; flushed in _emit_structure_deltas
                                                health<=0 → store.remove(id) + free cell
apply STRUCTURE_DELTA(remove) ◀──────────────── (remove prioritized under MAX_STRUCTURE_DELTAS_PER_TICK)
hold point, line blocked, off-cd ─GRENADE_THROW▶ validate (alive/cooldown[/ammo]) → spawn server grenade
                                                _step_grenades: arc; fuse done → detonate at P (present)
                                                  structures: cells_in_radius → apply_damage (removes/buckets)
                                                  pawns: sphere @ BLAST_RADIUS, falloff, FF-off → KILL
apply removes / KILL / respawn ◀──────────────── (deltas under send cap; overflow carried next tick)
```

---

## Out of scope for M4 Phase 2 (explicit)

Destructible **pre-placed environment cover** (deferred — reuses this exact cell-health model with a
map/catalog `start_health` when added); grenade **in-flight replication** and any client VFX /
`DETONATION` send (M7, with rendering — this phase ships the server-authoritative data a VFX layer
will consume); **per-fragment / voxel-shatter** physics (coarse cell-health only — a destroyed cell
simply frees); explosive **self-damage** and FF tuning (FF-off incl. self in v1); piece **repair**
(buckets only decrease); explosive **resource/supply economy** (rejected, as for building); new
weapon stats balancing beyond the gate constants. Building (Phase 1), movement, gunplay, and
Conquest are otherwise unchanged.
