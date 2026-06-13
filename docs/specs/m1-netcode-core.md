# Spec: M1 Netcode Core

**Status:** approved-pending-review · **Date:** 2026-06-13 · **Milestone:** [M1](../milestones/M1-netcode-core.md)

Covers the three M1 specs in one document: **wire protocol**, **replication** (snapshots + prediction/reconciliation/interpolation), and **interest management**. This is the highest-risk milestone; everything after it is "just gameplay" on top of this core.

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Determinism | **Authoritative float + client reconciliation** | Server is sole authority; normal floats. No cross-machine bit-determinism burden. BattleBit-style. |
| Snapshot model | **Per-client baseline + delta, with piggybacked acks** | Bandwidth-efficient and proven at high player counts. |
| M1 test entity | **Pawn moving via shared SimLoop over a flat ground plane**, random-walk bot input | Realistic enough that the 128p perf number is meaningful; no weapons/map (that's M2). |
| Encoding | **Byte-aligned** fields + per-entity change mask | Simpler to build/debug; escalate to bit-packing only if the budget needs it. |
| Tick rate | **30 Hz** fixed (`physics_ticks_per_second`) | Set in M0. |

## Budgets (the M1 gate pass/fail line)

- **Server tick:** mean step time **< 33.3 ms** at 128 players (30 Hz held). Also log p99 as a warning signal.
- **Per-client downstream:** target **≤ ~64 KB/s mean**; alarm above **~128 KB/s sustained** (~1 Mbit/s — trivial for modern connections).
- **Server aggregate out:** stay **< ~250 Mbit/s** at 128p (~25% of a 1 Gbit uplink), leaving headroom for voice (M6) and bursts.

> Bandwidth is intentionally generous (hosts have 1 Gbit uplinks, no caps). Fluidity — entity update fidelity/rate for nearby entities — is the lever we keep free; the budget exists only to catch pathological waste, not to constrain feel.

---

## Module layout (extends M0 `shared/`)

```
shared/net/
  net_host.gd        (exists) ENet transport + channels (CONTROL/SNAPSHOT/INPUT)
  protocol.gd        (exists) + ADD Msg.INPUT, Msg.SNAPSHOT
  quantize.gd        NEW  pos<->i32 mm, angle<->u16 helpers (+ round-trip tested)
  snapshot.gd        NEW  EntityState struct + baseline-delta encode/decode
  input_command.gd   NEW  input frame encode/decode
shared/sim/
  world.gd           NEW  entity registry: id -> pawn state, spawn/despawn
  pawn.gd            NEW  pawn state (pos, vel, yaw, pitch) + movement integration
  interest_grid.gd   NEW  uniform spatial hash; query(pos, radius) -> entity ids
  sim_loop.gd        (exists) step(dt, inputs): advance World by one fixed tick
shared/telemetry.gd  NEW  counters: tick µs, bytes/client, entity counts, starvation, loss
```

Server / client / bots remain **thin role scripts that drive these shared pieces**. Gameplay rules never fork into `client/` or `server/` (AGENTS.md §7) — this is what keeps prediction (client) and authority (server) from diverging.

---

## Wire protocol

All multi-byte fields little-endian via `StreamPeerBuffer`. First byte is `Protocol.Msg` type (M0 convention). Channels per `NetHost`: `CONTROL`(0, reliable), `SNAPSHOT`(1, unreliable-sequenced), `INPUT`(2, unreliable-sequenced).

> ENet note: a packet sent with **flags = 0** is *unreliable but sequenced* (stale packets dropped, newer kept) — exactly what input and snapshots want. Reliable (handshake) uses `FLAG_RELIABLE`.

### INPUT (client/bot → server, channel 2, flags 0)

| field | type | notes |
|---|---|---|
| msg type | u8 | `Msg.INPUT` |
| client_tick | u32 | client's local sim tick |
| ack_snapshot_seq | u32 | highest snapshot seq this client has received (piggybacked ack) |
| move_x, move_y | i16 | intended planar move, quantized [-1,1] → i16 |
| yaw, pitch | u16 | look angles, 65536/360° |
| buttons | u8 | bitmask (jump/crouch/prone/sprint/fire…); only a few used in M1 |

### SNAPSHOT (server → client, channel 1, flags 0)

| field | type | notes |
|---|---|---|
| msg type | u8 | `Msg.SNAPSHOT` |
| server_tick | u32 | authoritative tick this snapshot represents |
| snapshot_seq | u32 | per-client increasing sequence (baseline reference) |
| baseline_seq | u32 | the acked seq this is delta'd against (0 = full/keyframe) |
| last_input_tick | u32 | the client's last input the server has consumed (for reconciliation) |
| entity_count | u16 | number of entity records following |

Per entity record:

| field | type | notes |
|---|---|---|
| id | u32 | entity id |
| flags | u8 | bit0 ENTER (new in interest → full), bit1 LEAVE (left interest → drop), bit2 CHANGED |
| field_mask | u8 | present only if CHANGED/ENTER; which fields follow |
| pos_x/y/z | i32 | quantized mm; present if masked |
| yaw | u16 | present if masked |

(~4 fields ⇒ one mask byte suffices. Pitch omitted from replication in M1; pawns don't aim yet.)

---

## Data flow (per 30 Hz tick)

```
CLIENT / BOT                              SERVER (authoritative)
─────────────                             ──────────────────────
collect input
send INPUT(ch2) ───────────────────────▶ enqueue in per-client input jitter buffer
  {tick, ack=last_snap_seq, move, look}        │
                                               ▼  once per server tick:
                                          for each client: dequeue 1 input
                                            (or repeat last if starved → telemetry)
                                          SimLoop.step(dt, inputs)  // integrate pawns over ground
                                          for each client:
                                            interest = grid.query(pawn.pos, R)
                                            baseline = client.last_acked_snapshot
                                            build delta:
                                              ENTER  → full state for ids new to interest
                                              CHANGED→ masked changed fields vs baseline
                                              LEAVE  → ids that left interest
                                            snapshot_seq++ ; store in client history ring
   apply SNAPSHOT(ch1) ◀──────────────── send
   - own pawn → reconcile:
       snap to authoritative state,
       replay local inputs after ack
   - remote pawns → push into
       interpolation buffer (render ~100 ms behind)
```

**Bots** generate random-walk input and **ack snapshots but discard the payload cheaply** — they are load, not renderers, so 128 stay light in one process.

---

## Interest management

- **Uniform spatial hash grid** (`interest_grid.gd`). Config: cell size (default **64 m**), interest radius **R** (default **250 m**).
- Each tick, pawns are (re)bucketed into cells; `query(pos, R)` returns entity ids within R (cell-neighborhood scan).
- Per client, the interest set drives which entities appear in its snapshot (ENTER/CHANGED/LEAVE diff against its previous interest set).
- M1 recomputes interest per client per tick. If profiling shows it dominating the tick budget, cache per-cell results or stagger recompute across ticks (note for M1 implementation, not premature).

---

## Replication details

- **Per-client snapshot history ring** (last N snapshots, N≈32). The baseline for a client's next delta is its `last_acked_snapshot`; the server diffs current world state (restricted to interest) against that stored snapshot.
- **Keyframe resync:** `baseline_seq == 0` denotes a keyframe — the receiver resets its view to exactly the snapshot's entities (no LEAVE records needed). Per-client history is hard-capped at `MAX_HISTORY` (32) entries regardless of acks, so a non-acking client cannot grow it unbounded; once its baseline falls out of the capped history, the server naturally falls back to sending a keyframe.
- **Acks** ride on every INPUT frame (`ack_snapshot_seq`). No separate ack message.
- **Prediction/reconciliation (client):** client stores `(client_tick → input)` for unacked inputs. The snapshot's `last_input_tick` tells the client which inputs the server has consumed; on snapshot it sets its own pawn to the authoritative state, drops inputs with `client_tick ≤ last_input_tick`, and **replays** the rest. Smooth-correct small errors; hard-snap large ones.
- **Interpolation (client):** remote entities are rendered from a short buffer ~**100 ms** behind latest snapshot to hide jitter and packet loss.

---

## Error handling / edge cases

| Case | Handling |
|---|---|
| Snapshot lost | Client keeps last-acked baseline; server re-deltas against it next tick. |
| Client hasn't acked in N ticks | Server sends a **full keyframe** (baseline_seq=0) to resync. |
| Input starvation (no input this tick) | Server **repeats client's last input**; increments starvation counter (telemetry). |
| Late / duplicate input | Dropped by channel sequencing + `client_tick` monotonicity check. |
| Client clock drift | Absorbed by the interpolation delay buffer; no explicit clock-sync protocol in M1 (deferred to a later ADR if needed). |
| Peer disconnect mid-tick | World despawns the pawn; other clients get a LEAVE next snapshot. |

---

## Telemetry (gate evidence)

`shared/telemetry.gd` counters, logged by the server **once per second**:

- mean & **p99 tick step time** (µs)
- avg & **peak bytes/sec per client**, and **aggregate Mbit/s out**
- live entity / pawn count
- input-starvation count
- ENet packet loss (from `ENetPacketPeer` round-trip/loss stats)

These printed lines are the recorded evidence attached to the M1 gate.

---

## Testing

**Unit (headless, no server needed):**
- `quantize` round-trips position/angle within tolerance.
- `snapshot` encode→decode reconstructs identical `EntityState`.
- baseline-delta: encode against baseline B, decode on a client holding B, state matches; also the dropped-frame path (client still on older baseline).
- `interest_grid.query` returns exactly the ids within R (boundary cases at cell edges).
- reconciliation: given a divergent prediction + authoritative snapshot, replay converges to authoritative state.

**Integration / M1 gate:**
- `ci/m1_load_test.sh`: spawn server + bot fleet scaling 1 → 128, run ~60 s, parse telemetry, assert **mean tick < 33.3 ms** and **per-client downstream within budget**. Exit non-zero on breach.

---

## Out of scope for M1 (explicit)

Weapons / hit-reg, full map geometry, working lag-comp rewind (M2 builds it on the pawn position history — note: M1 does **not** add the history buffer; that was deferred per the chosen test-pawn scope), classes, UI/rendering polish, clock-sync protocol, bit-packed encoding.
