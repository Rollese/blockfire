# Native (Rust) snapshot encoder + parallel send — design

- **Date:** 2026-07-10
- **Ratifies:** [ADR-0003](../../adr/0003-native-snapshot-encoder.md) (Proposed → Accepted)
- **Enacts:** the escalation clause of [ADR-0001](../../adr/0001-core-runtime-language.md); toolchain
  precedent [ADR-0006](../../adr/0006-gdextension-voice-codec.md) / `native/voice_opus/`
- **Evidence base:** Phase 0 E-core profile — `docs/gate-evidence/20260710-163108-phase0-ecore-profile.txt`
  (peak tick 34.84 ms **FAIL** vs 33.3 ms budget; `snap` = 24.0 ms = ~69% of tick)
- **Settled constraints (not re-litigated, per `docs/reviews/2026-07-03-fable-goals-architecture-review.md` §A):**
  server authority + custom binary protocol on raw ENet stay; wire format unchanged; shared
  deterministic sim stays; sim step stays single-threaded; only the read-only snapshot send may
  be parallelized; Rust via `gdext` is the language.

## 1. Goal and scope decision

**Committed target (hard-gated): 128 players on budget hardware.** Phase A (native single-core
encoder) must flip the exact Phase 0 E-core config from FAIL (34.84 ms) to PASS with margin. This is
required *now* — every remaining roadmap item (hole-aware destruction, M13) adds per-tick work to a
tick that is already over budget on budget-class cores.

**Designed-for endgame: 256 players (Phase A + Phase B).** Phase B (parallel encode → serial send)
is fully designed here and the Phase A architecture is deliberately Phase-B-ready (immutable
end-of-tick columns, native-owned baselines, batch-shaped API). But Phase B **implementation is
deferred** until Phase A ships and either (a) a 256p milestone is actually scheduled, or (b) Phase A's
E-core margin proves insufficient under the destruction roadmap. Rationale: Phase 0 projects Phase A
alone restores budget at 128p (`snap` ≈ 24 ms → 5–8 ms); true 256p also needs netcode LOD work
(rate/precision falloff — see `server_main.gd` MAX_SNAPSHOT_ENTITIES note) that is out of scope
here, so building Phase B now would outrun the rest of the system.

Out of scope: any wire-format change; interest-management changes; `StructureStore.march()`
escalation; client/bot-side changes (decode stays GDScript everywhere).

## 2. Architecture overview

```
per tick (server, main thread):
  sim step (unchanged, single-threaded GDScript)
  SnapshotColumns.extract(world, weapon_by_id)        # GDScript: quantize once → flat columns
  enc.begin_tick(tick, ids, fields, vids, vfields, vseats, vseat_off)   # 1 FFI call
  for each client due this tick (stride):             # GDScript loop, unchanged bookkeeping
      interest ids  = _grid.query + enemy cull        # stays GDScript (measured 0.2 ms — no escalation)
      bytes = enc.encode_for(client_id, seq, want_baseline_seq,
                             last_input_tick, interest_ids, interest_vids)  # 1 FFI call
      _net.send_to(peer, ..., bytes)                  # serial send, main thread (unchanged)
      SELF_STATE + structure-baseline sync            # unchanged GDScript
acks:        enc.on_ack(client_id, seq)               # from the ack path
disconnect:  enc.remove_client(client_id)
weapon swap: enc.drop_entity_from_baselines(id)       # forces re-ENTER, mirrors _drop_from_history
```

The module is `native/snapshot_encoder/` (Rust, `gdext` 0.5.3 `api-4-6`, cdylib — mirrors
`voice_opus`). It exposes one class, `NativeSnapshotEncoder` (RefCounted), which **owns the
per-client baseline history natively**. The GDScript encoder (`shared/net/snapshot.gd` + dict
history in `server_main.gd`) stays intact as the **reference/fallback path** behind a sender seam.

### Considered alternatives

- **Thin FFI** (GDScript keeps dict history, passes current+baseline columns per client call):
  simpler module, but copies baseline data across the boundary every send, leaves the per-client
  dict bookkeeping (a real part of the 24 ms) in GDScript, and does not set up Phase B (workers
  would need Godot-owned data). Rejected.
- **Full-native including quantization** (pass raw f64 pos/angles, quantize in Rust): removes the
  GDScript extraction loop too, but duplicates `Quantize` semantics (`roundi` half-away-from-zero,
  `fposmod`) — a byte-parity risk surface for a loop that is cheap (≈128 × 6 quantize ops once per
  tick, not per client). Rejected for Phase A; revisit only if extraction measures hot.
- **C++ GDExtension**: rejected — ADR-0006 already established the Rust `gdext` toolchain and CI story.

## 3. Columnar state extraction (GDScript side)

New `shared/net/snapshot_columns.gd` (server-only caller, lives in `shared/net/` beside the codec):

- **Pawns:** `ids: PackedInt32Array` (world iteration order) and `fields: PackedInt32Array`,
  stride **10** per entity: `[q_px, q_py, q_pz, q_yaw, q_pitch, q_state, health, squad,
  armor_class, weapon]`. Quantized values computed exactly as `EntityState.bake()` does today
  (same `Quantize` calls, same state-byte packing). **`health` and `squad` are stored raw,
  unclamped/unmasked** — the encoder diffs raw values and clamps/masks only at write time,
  byte-identical to `_diff_mask`/`_put_fields` semantics.
- **Vehicles:** `vids: PackedInt32Array`, `vfields: PackedInt32Array` stride **7**:
  `[q_px, q_py, q_pz, q_heading, q_turret, hp, type]` (hp raw; clamp at write), plus seats as
  `vseats: PackedInt32Array` (flattened occupant ids) with `vseat_off: PackedInt32Array`
  (length = vehicle count + 1; per-vehicle start offsets).
- `weapon` comes from the client record (as today's stamp in `_send_snapshots`), passed in as a
  `weapon_by_id` Dictionary; ids without an entry get the `EntityState` default (0).
- Arrays are preallocated once and resized/reused per tick (no per-tick allocation churn).

Extraction replaces `World.state_map()` + per-entity `bake()` on the native path. `state_map()`
stays for the reference path and tests. Equivalence is unit-tested: for randomized worlds, columns
must equal the values `state_map()` + `bake()` produce field-for-field.

## 4. Native module: data model and API

### Owned state

- **Tick ring:** each `begin_tick` stores `(tick, ids, fields, vids, vfields, vseats, vseat_off)`
  plus an id→row index map (FxHashMap, lookup only — never iterated into output). Entries are
  **refcounted by the history records that reference them** and evicted when unreferenced.
  Defensive cap ~256 entries (stride 2 × MAX_HISTORY 32 = 64 ticks nominal); eviction of a
  still-wanted baseline is impossible by construction (history prune drops the ref first).
- **Per-client history:** `client_id → { seq → HistoryRec }` where `HistoryRec` =
  `{ tick_ref, sent_ids: Vec<u32> (in sent order), sent_id_set, sent_vids: Vec<u32>, sent_vid_set }`.
  This mirrors today's `c["history"][seq] = current` but stores **references to the shared tick
  columns + the ordered id subset** instead of per-client object maps — strictly less memory than
  the current dict-of-refs scheme. Pruned to `MAX_HISTORY = 32` seqs on insert and to `< acked_seq`
  on ack, matching `server_main.gd` exactly.

### Methods (the FFI boundary)

| Method | Called | Notes |
|---|---|---|
| `begin_tick(tick, ids, fields, vids, vfields, vseats, vseat_off)` | once/tick | Packed arrays cross as CoW slices — no per-field marshalling |
| `encode_for(client_id, seq, want_baseline_seq, last_input_tick, interest_ids, interest_vids) -> PackedByteArray` | per due client | Resolves baseline: `want_baseline_seq` present in history → delta; else keyframe (`baseline_seq = 0` on the wire, matching current fallback). Writes the full SNAPSHOT packet (header + pawn recs + vehicle recs). Records `HistoryRec` for `seq`. Returns the packet bytes. |
| `on_ack(client_id, acked_seq)` | ack path | Sets nothing GDScript-visible; prunes history `< acked_seq` (mirrors lines 1253–1256) |
| `remove_client(client_id)` | disconnect | Drops history, releases tick refs |
| `drop_entity_from_baselines(entity_id)` | weapon swap (`_drop_from_history`) | Removes id from every client's `sent_ids`/`sent_id_set` → next send emits ENTER |
| `reset()` | match rotation / tests | Clears everything |

GDScript keeps: `next_seq`, `last_acked_seq`, stride/degrade logic, interest query + enemy cull,
SELF_STATE, structure-baseline sync, telemetry byte counting (`bytes.size()` of the returned
buffer). The native module holds **no gameplay rules** — it is a codec + baseline store
(ADR-0006 leaf rule).

### Byte-identity invariants (the parity contract)

1. Pawn records iterate **exactly in `interest_ids` order**; LEAVE records iterate the stored
   baseline's `sent_ids` order (= GDScript Dictionary insertion order today). No sorting, no hash
   iteration into output — ordered `Vec`s only.
2. Diff compares raw column values (`health`, `squad`, `hp` unclamped; seats as whole lists);
   clamp/mask applied only at write (`health` → `clampi 0..255`, `squad & 0xFF`, `hp` →
   `clampi 0..65535`, `armor & 3`, `weapon & 0xFF`).
3. ENTER writes `F_ALL`/`VF_ALL` fields plus the two ENTER-only bytes (armor, weapon) for pawns.
4. Header layout, field-mask bit order, little-endian `StreamPeerBuffer` widths: unchanged,
   byte-for-byte.
5. Keyframe fallback: unknown/aged-out `want_baseline_seq` → empty baseline + `baseline_seq = 0`.

### Error handling

`encode_for` validates inputs (unknown interest id, ragged column length, stride mismatch) and on
any internal inconsistency logs via `godot_error!` and returns an **empty** `PackedByteArray`. The
GDScript caller treats an empty return as a native failure: logs a `SCRIPT ERROR`-visible error
(CI fails on those) and flips the session to the reference path permanently. `gdext` catches Rust
panics at the FFI boundary, so a bug degrades to fallback, never a server crash.

## 5. Sender seam and fallback

The seam is a path switch inside `server_main.gd:_send_snapshots()` (the loop's shared
bookkeeping — stride, structure sync, SELF_STATE, telemetry — is identical for both paths, so a
full class extraction would only add indirection; the encode-specific blocks are what branch):

- **Native path** (default when `ClassDB.class_exists("NativeSnapshotEncoder")`): columns +
  `begin_tick` + `encode_for` per client; no GDScript history dicts.
- **Reference path** (today's code, kept verbatim): `state_map()` + dict history +
  `Snapshot.encode`. Selected when the class is absent (Godot-only contributor, missing binary)
  or forced via `--encoder=gd` (fleet gates: `ENCODER=gd` env → compose passes
  `--encoder=${ENCODER:-native}`) for A/B runs.

`Snapshot.encode`/`decode_apply` and their tests stay untouched. Client and bots are unaffected
(decode is GDScript everywhere; the extension is loaded by the server process only — absence
elsewhere is a warning, as with `voice_opus`).

## 6. Parity verification (the hard gate)

Three automated layers, all in the deterministic suite; CI builds the Rust module so they run
loudly there (skip-with-notice only for local Godot-only runs):

1. **Roundtrip:** existing snapshot/vehicle-snapshot roundtrip tests re-run with native-encoded
   bytes through the unchanged GDScript `decode_apply`.
2. **Differential fuzz (primary):** a dual-run harness drives **both** encoders through the same
   multi-tick scenarios — seeded-random walks over enter/leave/field-change, ack gaps and
   reordering, interest churn + enemy-cull subsets, weapon-swap `drop_entity_from_baselines`,
   client join/leave, keyframe aging — asserting **byte equality of every packet** and equal
   history side effects (via a native introspection hook for tests). Seeded PRNG → reproducible.
3. **Golden vectors:** committed binary fixtures (inputs + expected bytes) generated once from the
   GDScript reference; both encoders must match them. Catches drift when *either* side changes.

Plus a one-off live audit: a `--parity-audit` server flag runs both encoders per send and compares
during **one** fleet-gate run (costed run, then turned off). Proves parity under real 128-bot
traffic, not just synthetic scenarios.

## 7. Phase B — parallel encode, serial send (designed now, built later)

- **API:** `encode_batch(requests: Array) -> Array` where each request is
  `[client_id, seq, want_baseline_seq, last_input_tick, interest_ids, interest_vids]` and the
  return is positionally matched `PackedByteArray`s. GDScript prepares all due clients' interest
  lists first (serial, cheap), makes **one** FFI call, then loops the returned buffers through
  `_net.send_to` + SELF_STATE on the main thread. ENet is never touched off-main-thread.
- **Safety:** workers read only the immutable tick ring + per-client history (each client's
  history is touched by exactly one worker — clients are partitioned, never shared). No Godot API
  in workers. Sim untouched. History mutation (`HistoryRec` insert/prune) happens inside each
  client's own encode task; `on_ack`/`remove_client` remain main-thread-only between batches.
- **Pool:** rayon, `workers = min(4, physical cores)` default, `--encode-workers=N` override.
  Per-client output buffers pooled (retain capacity across ticks); converted to `PackedByteArray`
  once at the boundary.
- **Parity:** `encode_batch` output must byte-equal per-client `encode_for` output (differential
  test), which transitively pins it to the GDScript reference.
- **Gate:** encode wall-time vs worker count (expect near-linear to 3–4×), plus a raised-player-
  count fleet run when 256p work is actually scheduled.

## 8. Build / CI / deployment matrix

**Linux x86_64 only.** The encoder is server-side; every server host is Linux x86_64 (game2 dev +
fleet, docker containers, Unraid production, GitHub CI ubuntu). No Windows/macOS builds — the
client never encodes. (`.gdextension` gets linux entries only; extend later if a listen-server
ever exists.)

- `native/snapshot_encoder/`: crate mirroring `voice_opus` (gdext 0.5.3 `api-4-6`, cdylib,
  `compatibility_minimum 4.6`, source committed, binary gitignored via existing `*.so` rule).
  Pure-Rust unit tests (`cargo test`) for the encoder core — the wire-writing core is a plain
  Rust function testable without Godot.
- **game2 / fleet:** build once per checkout (`cargo build --release`), docker `COPY . /app`
  already picks up `native/*/target/release/*.so` (`.dockerignore` does not exclude it —
  verified). Gate scripts gain a fail-fast check that the `.so` exists.
- **GitHub CI:** add rustup + cargo-cache + `cargo build --release` steps before the import step;
  parity tests **fail** (not skip) when the class is missing and `CI=true`.
- **Fallback:** binary absent → warning + reference path; dev on Godot-only machines keeps working
  (ADR-0001 contributor story preserved).

## 9. Performance instrumentation and gates

**Instrumentation first:** before any Rust lands, split the `snap` bucket into sub-buckets —
`snap_query` (per-client grid query + cull), `snap_enc` (state extraction + encode), `snap_send`
(ENet send calls), `snap_struct` (structure-baseline sync), `snap_self` (SELF_STATE) — and re-run
the Phase 0 E-core profile. This converts the "~80–90% addressable" estimate into a measured
number, sets the honest Phase A target, and gives post-change attribution.

**Phase A hard gate (the flip):** 128-bot `conquest_town` fleet gate, server pinned to E-cores
16–19 (the exact Phase 0 FAIL config):

- Reference path (`ENCODER=gd`): expected FAIL ≈ 34.8 ms — the "before" evidence.
- Native path: **peak tick < 33.3 ms with margin (target ≤ ~22 ms), `snap_enc` ≤ ~6 ms** (from
  ~20 ms addressable), p99 under budget. Evidence committed to `docs/gate-evidence/`.
- Plus the standard P-core gate (must not regress) and the full deterministic suite green.

**No-regression:** connect smoke, telemetry byte-count parity (native path reports identical
per-client byte totals as reference in the differential harness), 0 script errors.

## 10. Risks

- **Parity drift when GDScript reference changes** (new wire field): golden vectors + fuzz fail
  loudly; the plan adds a checklist note to `snapshot.gd` — any wire change must update both
  encoders + regenerate vectors. VERSION bump discipline already exists (wire registry).
- **gdext/Godot version skew:** pinned 0.5.3/api-4-6 like voice_opus; upgrading Godot is already a
  project-wide event.
- **Native memory growth:** bounded by refcounted tick ring + MAX_HISTORY; the differential
  harness asserts ring size stays ≤ nominal window under churn.
- **Rust unavailable on a host:** reference path keeps the server functional (slow) — visible in
  `[perf]` and gate evidence, not a silent failure.
