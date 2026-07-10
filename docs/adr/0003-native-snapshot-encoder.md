# ADR-0003: Native (Rust) snapshot encoder + parallel send

- **Status:** Accepted (2026-07-10 — ratified by the deep-planning pass; design in
  [docs/superpowers/specs/2026-07-10-native-snapshot-encoder-design.md](../superpowers/specs/2026-07-10-native-snapshot-encoder-design.md),
  plan in [docs/plans/2026-07-10-native-snapshot-encoder.md](../plans/2026-07-10-native-snapshot-encoder.md))
- **Date:** 2026-07-10
- **Context milestone:** post-M16 perf track
- **Supersedes/enacts:** the escalation clause in [ADR-0001](0001-core-runtime-language.md)
  ("if GDScript misses the budget, open **ADR-0003** to escalate the identified hot path to
  GDExtension"). Precedent: [ADR-0006](0006-gdextension-voice-codec.md) (first Rust `gdext` module).

## Context

The per-tick snapshot encode path (`snap` bucket) is the dominant server cost and the escalation
condition ADR-0001 anticipated has arrived on dense maps:

- **Measured `snap` share.** On `conquest_town` (8324 pieces, 128 bots) the `snap` bucket is the #1
  `[perf]` bucket. **Pinned 14900KS P-cores (0–3): peak `snap` ≈ 14.0 ms** of a ~24–26 ms peak tick
  (`docker/srvlog-m17-reserve-ammo-20260710-003052.log`, `…netcode-bulk-channel-20260710-003919.log`)
  — i.e. **~55% of the whole tick**.
- **Budget-hardware reality (Phase 0 — MEASURED).** The 33.3 ms budget was only ever validated on
  top-end pinned P-cores. The server tick is **single-threaded**, so single-thread perf is what
  matters, and production will run on slower silicon (budget Ryzen / older Xeon / cloud vCPU, commonly
  1.5–3× slower single-thread). **Phase 0 (server pinned to 4× 14900KS E-cores as a slower-core proxy,
  bots on the P-cores): peak `snap` ≈ 24.0 ms (up from 14.0 ms on P-cores, ×1.72), peak tick 34.84 ms,
  peak tick p99 37.46 ms — GATE FAIL vs the 33.3 ms budget** (`docs/gate-evidence/20260710-163108-phase0-ecore-profile.txt`).
  `snap` is **~69% of the whole tick** on slow cores, and the `interest` query is a *separate* 0.2 ms
  bucket — so `snap` is almost entirely the addressable clone + dict + encode + send-call work, and it
  scaled 1.72× purely from slower cores, confirming it is **GDScript-CPU-bound**.
- **Every remaining roadmap item lands on this tick:** hole-aware destruction marching (per-bullet
  server cost), air vehicles (M10), more players / M13. On the fast host the dense-map headroom is
  3–6 ms; **on the budget proxy the headroom is negative — the tick is already over budget before any
  new per-tick work is added.** This makes the escalation **required for budget hardware, not
  optional.**

The hot path is well-localized (exactly what ADR-0001's interface-boundary design intended):
`World.state_map()` clones 128 `EntityState` objects/tick (`shared/sim/world.gd:29-33`); per-client
dict + `StreamPeerBuffer` allocation and the interpreted diff/field-write loop in `Snapshot.encode()`
(`shared/net/snapshot.gd`). The last algorithmic win (`EntityState.bake()`, 2026-07-01) already cut
encode −52% in pure GDScript; the remaining cost is the **interpretation tax + per-tick allocation**,
which only an execution-model change removes.

## Decision

Escalate the snapshot encode path to a native **Rust `gdext`** module (matching `native/voice_opus/`),
in **two phases**, behind the existing `Snapshot.encode` interface, with **byte-identical output** as
a hard contract.

**Phase A — native columnar encoder (single-core win, ships first).**
- Replace per-tick `EntityState` cloning with a **columnar state-extraction layer**: extract wire
  fields once into flat packed arrays (quantized pos, state byte, health, squad, …). No per-object
  GDScript allocation.
- A native function consumes `(columns, per-client baseline, interest id set)` and produces the delta
  byte buffer — the diff + write loop runs in Rust with no binding-crossing-per-field and no GC.
- Baselines-per-client (the ack `history`) stored in the same columnar form.
- **Output is bit-identical to the current GDScript encoder** — verified by the existing roundtrip
  tests + a golden-vector parity test. GDScript encoder stays as the reference/fallback.

**Phase B — parallel send (the multicore / 256-player endgame).**
- Fan the per-client encode across a worker pool (`WorkerThreadPool` or native threads). Safe because
  Phase A's columns are **immutable end-of-tick data** (read-only shared, disjoint output buffers).
- The actual socket send stays serialized on the main thread (ENet peer send is not concurrent-safe):
  **encode in parallel → drain + send on the main thread.**
- **The sim step stays single-threaded** — determinism is load-bearing (client prediction re-runs the
  same `shared/sim/` code); only the read-only send fans out.

Second native candidate, only if Phase 0 / re-profiling demands it: `InterestGrid.query()` +
`StructureStore.march()` (the review's named second target). Out of scope for this ADR unless measured.

## Rationale

- **BattleBit parity is runtime + threading, not algorithm.** BattleBit's 256-on-a-VPS comes from a
  compiled/JIT runtime (C#) running across all cores. This ADR buys, for our single hottest path, the
  execution class their whole server has for free (Phase A), and the multicore usage (Phase B).
- **Proportional & reversible.** Only the proven hot path goes native, behind a narrow interface, with
  a GDScript reference kept — exactly ADR-0001's escalation model. Everything else stays testable
  GDScript.
- **Phase A structurally unlocks Phase B.** Columnar immutable data is what makes parallel encode safe;
  the current object-cloning path cannot be threaded safely. Build A before B.
- **Determinism preserved.** Byte-identical contract + sim-stays-serial means no gameplay/prediction
  risk.

## Consequences

- Adds a **per-platform native build/CI step** (mitigated: `voice_opus` already establishes the
  `gdext` toolchain + CI pattern; binary gitignored, source committed).
- Native code is harder to change → **review-heavy** implementation (subagent-driven with review
  subagents on integration tasks) and a **byte-parity gate** as the hard check, not "looks right".
- Requires Rust + `gdext` familiarity to maintain.
- If a platform binary is missing, the GDScript reference path is the fallback (no hard dependency for
  dev/test on Godot-only).

## Verification / gates — Phase A MEASURED RESULTS (2026-07-10, implementation landed)

1. **Parity: PASS.** Differential fuzz (3 seeds × 120 ticks × 4 clients, byte-equal every packet:
   `tests/native_parity_fuzz_test.gd`), golden vectors pinning both encoders
   (`tests/snapshot_golden_test.gd` + `tests/fixtures/`), smoke keyframe test, and a **live
   `--parity-audit` 128-bot fleet run: 0 mismatches** across a full `conquest_town` match
   (`docs/gate-evidence/20260710-175356-phaseA-parity-audit.txt`).
2. **Phase A perf gate: PASS — the flip happened.** Same branch build, same E-core-pinned config:
   `ENCODER=gd` **FAIL 35.05 ms** (`…175207-phaseA-ecore-gdref.txt`) vs native **PASS 28.87 ms**
   (`…174956-phaseA-ecore-native.txt`). `snapenc` (the addressable sub-bucket, measured by the new
   Task 1 instrumentation at 13.4 ms of `snap`=23.9 ms) dropped to **0.46–0.9 ms (~15–29×)**. The
   residual E-core peak window is the structure-baseline join flood (`snapstruct` 12.3 ms) — a
   separate, pre-existing cost outside this ADR's scope.
3. **Phase B perf gate:** deferred with Phase B (unchanged: encode wall-time vs worker count,
   near-linear scaling).
   **A.5 addendum (2026-07-10, owner-ratified):** interest membership + enemy cull also moved
   native (`encode_for_auto`), plus structure-baseline scan memoization. For this layer the
   byte-identical contract is deliberately relaxed to **decoded-view equality** (record order =
   column order; decode is order-independent) — verified by an oracle view-parity fuzz harness
   (`tests/native_interest_view_test.gd`); the byte-level fuzz/golden suites still pin the codec
   core through explicit-interest `encode_for`. E-core gate improved **28.87 → 22.70 ms**
   (`snapq` 6.8 ms → ~10 µs; steady `snap` ≈ 2.8 ms) —
   `docs/gate-evidence/20260710-183739-phaseA5-ecore-native.txt`.
4. **No-regression: PASS.** Suite 1463/0 (was 1456 + new parity/columns tests), connect smoke green,
   P-core fleet gate **18.38 ms peak** vs the ~24–26 ms historical baseline
   (`…175544-phaseA-pcore-native.txt`), GitHub CI green incl. the new Rust build steps (PR #2).

## Phase 0 evidence (measurement-first, this seed)

Method: 128-bot fleet gate on `conquest_town` (dense = worst case for `snap`), server pinned to 4
cores, bots on the rest. P-core run vs E-core run isolate single-thread CPU class (E-cores ≈ a budget
CPU proxy). Per-tick phase breakdown from the server's `[perf] us/tick:` line; peak window shown.

| Metric (peak window) | P-cores 0–3 (fast) | E-cores 16–19 (budget proxy) | ratio |
|---|---|---|---|
| `snap` bucket | 14.0 ms | **24.0 ms** | ×1.72 |
| peak tick | ~24–26 ms | **34.84 ms** | — |
| peak tick p99 | — | **37.46 ms** | — |
| `snap` % of tick | ~55% | **~69%** | — |
| budget (33.3 ms) | PASS | **FAIL** | — |

Evidence: `docs/gate-evidence/20260710-163108-phase0-ecore-profile.txt` (E-core, FAIL),
`…-m17-reserve-ammo-…` / `…-netcode-bulk-channel-…` (P-core baselines). 0 script errors, kills=26
(combat unaffected — this is a pure perf profile). The slow-core peak `[perf]` line:
`poll=3600 move=4339 … interest=211 fire=540 … snap=24031 (ticks=31)` — `snap` dwarfs every other
phase; `interest` (the second native candidate) is only 0.2 ms and does **not** need escalation yet.

**Interpretation.** `snap` is GDScript-CPU-bound (scales ~linearly with single-thread perf: ×1.72 as
cores slowed) and already breaches budget on budget-class hardware. Since the `interest` query is
separate and tiny, ~80–90% of `snap` is addressable by the native encoder (clone + dict + encode
loop; only the ENet `send()` calls inside `snap` stay). **Projection (to be confirmed by the Phase A
gate):** cutting the addressable ~20 ms of the E-core `snap` by ~3–5× → `snap` ≈ 5–8 ms → total tick
≈ 16–19 ms, back **well under budget with headroom for destruction**. So **Phase A alone is expected
to restore budget at 128p on budget hardware; Phase B (parallel send) is for the 256-player / extra-
margin endgame, not for merely hitting 33.3 ms at 128p.**

## Ratified decisions (2026-07-10 planning pass)

Full rationale + alternatives in the
[design doc](../superpowers/specs/2026-07-10-native-snapshot-encoder-design.md); summary:

- **Ambition.** The committed, hard-gated target is **128p on budget hardware via Phase A**.
  256p is the designed-for endgame: Phase A is built Phase-B-ready (immutable tick columns,
  native-owned baselines, batch-shaped API), but **Phase B implementation is deferred** until a
  256p milestone is scheduled or destruction work erodes Phase A's margin. True 256p also needs
  rate/precision LOD netcode that is out of this ADR's scope.
- **Column schema.** Quantization stays in GDScript (`shared/net/snapshot_columns.gd`, same
  `Quantize`/`bake()` math — zero quantization-parity risk). Per tick: pawn `ids` +
  stride-10 `PackedInt32Array` `[q_px q_py q_pz q_yaw q_pitch q_state health squad armor weapon]`
  (health/squad **raw**; clamp/mask at write time, matching `_put_fields`); vehicles stride-7 +
  flattened seats with offsets.
- **Baselines stored natively.** `NativeSnapshotEncoder` owns a refcounted **tick-column ring** +
  per-client history of `(seq → tick ref + ordered sent-id list)`, mirroring
  `c["history"]`/MAX_HISTORY/ack-prune semantics exactly (including `_drop_from_history` for the
  weapon-swap re-ENTER). GDScript keeps seq allocation, stride/degrade, interest, SELF_STATE,
  structure sync.
- **FFI shape.** `begin_tick(columns)` once per tick; `encode_for(client_id, seq,
  want_baseline_seq, last_input_tick, interest_ids, interest_vids) -> PackedByteArray` per due
  client (keyframe fallback resolved natively); `on_ack` / `remove_client` /
  `drop_entity_from_baselines` / `reset`. Packed arrays in, one packet buffer out — no per-field
  crossings. Record order = `interest_ids` order; LEAVE order = stored sent order; no hash-map
  iteration ever reaches the wire.
- **Parity strategy (hard gate).** (1) existing roundtrip suite over native bytes; (2) a
  seeded **differential fuzz harness** running reference + native side-by-side over multi-tick
  enter/leave/ack-churn scenarios asserting byte equality of every packet — the primary gate;
  (3) committed **golden vectors** pinning both encoders; plus a one-off `--parity-audit` fleet
  run comparing both live. Native errors return an empty buffer → logged + permanent in-process
  fallback to the reference path.
- **Interest query stays GDScript.** Phase 0 measured it at 0.2 ms on E-cores — no escalation. A
  new `snap_*` sub-bucket instrumentation pass lands **before** Rust to measure the addressable
  share precisely and attribute the win.
- **Phase B handoff.** GDScript precomputes all due clients' interest lists, one
  `encode_batch(requests) -> Array[PackedByteArray]` call fans encode over a rayon pool
  (`min(4, cores)` workers, `--encode-workers=N`), workers touch only immutable columns + their
  own client's history, buffers pooled in Rust; **send stays serial on the main thread** (ENet is
  not thread-safe). Batch output must byte-equal per-client `encode_for` output.
- **Build/CI matrix: Linux x86_64 only.** The encoder is server-side and every server host
  (game2, docker fleet, Unraid, CI) is Linux x86_64; the client never encodes. Crate
  `native/snapshot_encoder/` mirrors `voice_opus` (gdext 0.5.3 `api-4-6`, source committed,
  binary gitignored). Docker `COPY . /app` picks up the host-built `.so` (gate scripts fail fast
  if missing); GitHub CI gains rustup + cargo-cache + build steps, and parity tests **fail** (not
  skip) in CI when the class is missing. Binary absent elsewhere → reference path (ADR-0001
  Godot-only contributor story preserved).
