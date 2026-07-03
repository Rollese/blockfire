# Fable architecture second opinion — 2026-07-03

Owner-requested independent audit (Fable 5) of all Opus-built work to date, on master `1042a22`.
Unlike the 2026-07-02 deep investigation (bug-hunting), this review evaluates the architecture
against the owner's three **stated future goals**:

1. **High client performance** (high FPS, low frame-time variance)
2. **High-efficiency, low-lag netcode**
3. **High-fidelity environment destruction**

Method: four parallel read-only deep dives (netcode, server sim + gate evidence, destruction,
client rendering) over the full source, ADRs, specs, and committed `docs/gate-evidence/` logs.
File:line refs are to master `1042a22`. Read-only — no code was changed by this review.

**Overall verdict: no change of direction is warranted anywhere.** Server authority, the custom
binary protocol on raw ENet, the shared deterministic sim, and gate-driven development are all
correct calls, repeatedly proven at 128 bots. The findings below are (a) two planned
*escalations* (not rewrites) that future feature work should account for, (b) the honest
ceiling of the destruction architecture, which the owner should ratify explicitly, and (c) a
set of internet-play gaps that are fine on LAN but block the "low lag" goal at real pings.

---

## A. What is sound — do not re-litigate

Future agents should treat these as settled (each is evidenced, not assumed):

- **Transport & protocol.** Raw `ENetConnection` with a custom byte-packed protocol
  (`shared/net/net_host.gd`, `shared/net/protocol.gd`) — deliberately *not* Godot's high-level
  MultiplayerSynchronizer/RPC, which does not scale to 128 players. Keep it.
- **Snapshot scheme.** Per-client baseline+delta with piggybacked acks, mm-quantized positions,
  u16 angles, keyframe fallback when the baseline ages out (`shared/net/snapshot.gd`,
  `server/server_main.gd:757-814`). The wire format is compact and correct; do not redesign it.
- **Interest management.** 64 m spatial-hash cells, 250 m radius, enemy relevance cull
  (`shared/sim/interest_grid.gd`, `server_main.gd:15-26`), plus the `server/degrade.gd`
  adaptive ladder. Adequate at 128p; extend (e.g. for air vehicles) rather than replace.
- **Prediction/reconciliation.** Full shared-sim replay prediction (`client/prediction.gd`),
  100 ms interpolation buffer (`client/interpolation.gd`), 3-frame input redundancy. The
  shared-`SimLoop` discipline (AGENTS.md §7) is what makes this work — never fork rule logic.
- **Custom kinematic sim, zero Godot physics.** No `PhysicsServer`/`CharacterBody3D` anywhere
  in `shared/sim/` — this is why the sim is deterministic, headless-testable, and shared. Any
  future feature that reaches for Godot physics on the server is architecturally wrong here.
- **Chunk-mask destruction substrate.** 2 m pieces + 64-bit face alive-masks
  (`shared/sim/chunk_mask.gd`, `shared/sim/structure.gd`), event-driven interest-scoped
  replication (~13 B per chunk event), paced baselines. Passed the 8324-piece `conquest_town`
  gate at 128 bots. It is the right *family* of design for networked destruction.
- **Client structure rendering.** Version-gated sync + MultiMesh batching by visual key
  (`client/world_renderer.gd:1969-2089`) — took the dense map from a measured ~21 FPS
  (35 ms/frame of GDScript re-posing) to a few hundred draw calls. FX strictly pooled and
  capped (`client/fx_pool.gd`).
- **Process discipline.** Per-phase `[perf]` tick profiling, deterministic mechanic tests
  (~1080/0), fleet gates with committed evidence. The two historical budget blows (95 ms at
  M3, 34.08 ms dense-map at M11) were both found by measurement and fixed algorithmically
  (snapshot stagger; `EntityState.bake()` −52% encode). Keep gating this way.

---

## B. Goal 1+2 — the two planned escalations

### B1. Snapshot encode path → GDExtension (write ADR-0003 before stacking new per-tick work)

ADR-0001 chose GDScript-first with an explicit escalation condition: "if GDScript misses the
budget, open ADR-0003 to escalate the identified hot path to GDExtension." **That condition
has effectively arrived on dense maps.** Evidence:

- `snap` is the dominant `[perf]` bucket (~16 ms of a ~33 ms peak tick at M4-era peaks; still
  #1 after the M11 bake fix — see `docs/specs/client-prediction.md` handover note).
- Dense-map gates pass at **27–30 ms peak vs the 33.3 ms budget** (M11 `conquest_town`
  27.31 ms; M7.5 AI town 29.70 ms) — only **3–6 ms headroom**, and every remaining roadmap
  item (M10 air vehicles, richer destruction, M13) lands on top of it.
- The default-map stress headroom (16.7 ms peak, 2026-07-03) is healthy, but that is the
  *easy* profile.

The hot path is well-localized, exactly as ADR-0001 intended: `World.state_map()` clones 128
`EntityState` per tick (`shared/sim/world.gd:29-33`), per-client dict/`StreamPeerBuffer`
allocation in `Snapshot.encode()`, and the per-field diff loop. A native (Rust `gdext` or C++)
encoder + state-extraction layer behind the existing interface is the proportional move.
**Do this before, not after, adding air vehicles or hole-aware destruction to the tick.**
Interim GDScript wins still available if native is deferred: reuse pooled `EntityState`
buffers instead of per-tick clones; skip the full-`baseline`-keys LEAVE scan
(`snapshot.gd:59-62`).

Second native candidate (only if profiling demands): `StructureStore.march()` +
`InterestGrid.query()` under high projectile load (`server/fire.gd` per-segment marches,
pool cap 1024).

Caveat for all headroom numbers: every gate ran on pinned P-cores of a 14900KS (AGENTS.md §8).
A weaker production host has less margin than the logs suggest — re-validate once on an
unpinned/weaker host before treating headroom as real.

### B2. Client remote-player draw path → instancing (the FPS ceiling)

Structures got batched; **players did not**. Every visible remote is a pooled `Node3D` scene
(GLB by default) with its own `AnimationPlayer` and per-frame GDScript pose work
(`world_renderer.gd:1722-1738`, `2312-2322`, `_pose_entity` at `1814-1945`). Part-level
`visibility_range` LOD (`client/art/lod.gd`: 35 m / 70 m / proxy box) helps GPU but the
per-player script cost remains. Interest (250 m) bounds the visible set, but a big
point-fight with 50–80 visible players will not hold high FPS on this path.

Recommended order (from the client deep dive):
1. MultiMesh/instanced remote players (shared transform buffers, single material — same
   pattern that fixed structures). This is the single biggest lever for goal 1.
2. Skip pose/anim work for off-screen entities (engine frustum culls draws, not GDScript).
3. Shadow policy: structure MultiMeshes all cast shadows (`world_renderer.gd:2054`) and
   buildings have no distance LOD — cheap wins on dense maps.
4. Only then consider native render-assembly code.

Also: **client FPS has no regression gate** — server tick is hard-gated, client perf is
owner-playtest only (ADR-0005). Three separate per-frame regressions (structure re-pose 35 ms,
compass ~10 ms, scoreboard ~650 allocs/frame) shipped and were caught later by playtest or
review. A scripted flythrough on `conquest_town` with a frame-time budget, run like a `ci/`
smoke, would guard goal 1 the way the fleet gate guards the tick.

---

## C. Goal 3 — destruction: sound substrate, implementation lags its own spec

The biggest concept-vs-reality gap in the project. Chunk masks are tracked, replicated, and
tested — but **partial damage currently affects nothing except a 4-tier damage-mesh swap**
(`world_renderer.gd:2252-2265`):

- A piece blocks bullets, movement, and LOS while *any* chunk is alive — you cannot shoot,
  see, or move through a hole. `StructureStore.march()` tests whole-cell AABBs and never
  reads chunk bits (`structure.gd:219-247`). The spec explicitly defers hole-aware march
  (`docs/specs/destructible-buildings.md` §cover) — that deferral is now the main blocker to
  destruction *gameplay*.
- The spec'd per-chunk hole renderer (MultiMesh of up to 64 cubes per damaged piece,
  `destructible-buildings.md` §render) is not built.
- Collapse cinematics are partial (generic rubble mound at the last-dirty-piece position, no
  sink/smoke — `world_renderer.gd:2345-2410` vs spec).

**Path forward is extension, not rewrite** — in this order: (1) hole-aware `march()` +
penetration using `ChunkMask.is_alive_at()`, (2) per-chunk hole rendering, (3) the
edge-aligned wall/finer-grid work already sketched in
`docs/specs/building-overhaul-proposal.md`. Mind the B1 headroom note: hole-aware marching
makes every bullet segment more expensive on the server.

**Ceiling to ratify in an ADR:** this architecture tops out at BattleBit/Enlisted-class
*localized* destruction. Physics debris that affects gameplay, continuous fracture, or
Teardown-style voxel simulation are incompatible with the 128-player authoritative
determinism this project is built on and would be a separate subsystem, not an iteration of
`StructureStore`. If the owner's "high fidelity" ambition is the former, the roadmap above
covers it; if the latter, that must be planned as its own track — decide explicitly rather
than discovering it mid-milestone. *(Decided 2026-07-03: see
[ADR-0008](../adr/0008-destruction-fidelity-target.md) — "BattleBit-plus" hybrid; Teardown-class
authoritative physics ruled out.)*

Smaller destruction-layer notes for whoever picks this up: `OP_CHUNK` sends the full u64 mask
per event (fine at the 64/tick cap; wasteful under sustained MG fire on few pieces);
`COLLAPSE` broadcasts to all 128 clients, not interest-scoped (`server_main.gd:1698-1708`);
support cascade runs one BFS per building per tick, not the spec's iterative fixed-point —
multi-stage orphan chains resolve a tick late (`shared/sim/support.gd`).

---

## D. Goal 2 at internet pings — LAN-fine, not yet "low lag" beyond it

Current tuning is explicitly LAN-first (ADR-0005 context). Before any public/high-ping play:

1. **Infantry fire has no lag compensation.** Bullets resolve at present time
   (`server/fire.gd:136-138`); only mounted guns rewind to the gunner's `view_server_tick`
   (`fire.gd:41-58`, `server/lag_comp.gd`). Deliberate and acceptable at LAN pings; at
   80–100 ms it breaks shoot-where-you-see on moving targets. The rewind machinery and the
   `view_server_tick` plumbing already exist — extending them to infantry hit tests (or
   projectile spawn rewind) is incremental. Note `LagComp.record()` currently only runs when
   a mounted gunner exists (`server_main.gd:341-347`) — that gate would need to lift.
2. **Vehicle driver prediction is spec'd but not implemented** — all occupants including the
   driver are position-slaved to snapshots (`client/client_main.gd:267-275`,
   `docs/specs/client-prediction.md`). This is the most feelable input latency in the game.
3. **All reliable traffic shares ENet channel 0** — handshake, SELF_STATE (sent reliable every
   snapshot stride), structure baselines/deltas, rosters, lists. One measured head-of-line
   incident already (~170 ms p99 at 48 bots from a baseline flood, fixed by the 256-piece/tick
   pacer, `server_main.gd:47-51`). Split reliable priorities onto separate channels (ENet
   supports more), or demote low-criticality lists to unreliable+heartbeat.
4. **Effective per-client snapshot rate is ~15 Hz** (`SNAPSHOT_STRIDE = 2`,
   `server_main.gd:18`). Interpolation hides it, but it is the remote-fidelity ceiling; a
   native encoder (B1) is what would buy stride 1 back at 128p.

---

## E. Suggested execution order

| Priority | Item | Section |
|---|---|---|
| 1 | ADR-0003 + native snapshot encoder/state extraction (or at minimum the GDScript alloc fixes) | B1 |
| 2 | Instanced remote-player rendering | B2 |
| 3 | Hole-aware collision/LOS + per-chunk hole rendering (destruction gameplay) | C |
| 4 | Client frame-time smoke gate (scripted flythrough, budget in ms) | B2 |
| 5 | Infantry lag comp + vehicle driver prediction (pre-internet-play) | D1, D2 |
| 6 | Reliable-channel split | D3 |
| 7 | Headroom re-validation on a non-pinned host | B1 |
| 8 | ADR ratifying the destruction fidelity target (Enlisted-class vs separate physics track) — **done: [ADR-0008](../adr/0008-destruction-fidelity-target.md)** | C |

Items 1–4 serve the owner's three goals directly; none block the current in-flight work
(M7 playtest gate, M7.5 P3/P4, M6 wiring). Items 5–6 gate any move beyond LAN. Sequencing
note: do item 1 before item 3 — hole-aware marching adds server cost that the current
dense-map headroom (3–6 ms) cannot comfortably absorb.
