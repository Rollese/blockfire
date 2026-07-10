# ADR-0003: Native (Rust) snapshot encoder + parallel send

- **Status:** Proposed (seed — for a deep-planning/brainstorming pass; not yet ratified)
- **Date:** 2026-07-10
- **Context milestone:** post-M16 perf track
- **Supersedes/enacts:** the escalation clause in [ADR-0001](0001-core-runtime-language.md)
  ("if GDScript misses the budget, open **ADR-0003** to escalate the identified hot path to
  GDExtension"). Precedent: [ADR-0006](0006-gdextension-voice-codec.md) (first Rust `gdext` module).

> **This is a seed, not a finished decision.** It captures the analysis + measurements so a
> deep-reasoning planning pass (brainstorming → `writing-plans`) can produce the ratified ADR and a
> phased implementation plan. Sections marked _(fill)_ are pending Phase 0 evidence.

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

## Decision (proposed)

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

## Verification / gates

1. **Parity:** Rust encoder output == GDScript encoder output, byte-for-byte, across the existing
   roundtrip suite + golden vectors (hard automated check).
2. **Phase A perf gate:** 128-bot fleet gate on `conquest_town`, **run E-core-pinned (the Phase 0
   config that FAILED at 34.84 ms)** — target `snap` ≈ 5–8 ms (from ~24 ms) and peak tick back under
   33.3 ms with margin. This exact config failing today and passing after is the proof.
3. **Phase B perf gate:** scaling test — encode wall-time vs worker count; push player count upward and
   confirm near-linear send scaling with cores.
4. **No-regression:** full deterministic suite green; connect smoke; telemetry parity.

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

## Open questions for the planning pass

- Column schema + how baselines are stored natively (packed-array copies vs native handles).
- FFI boundary shape: pass `PackedByteArray`/`PackedInt32Array` columns in, get `PackedByteArray` out?
- Phase B worker-pool ownership, buffer pooling, and the parallel-encode → serial-send handoff.
- Whether `InterestGrid.query()` must also go native to hit budget on slow hosts (Phase 0 decides).
- Windows/Linux/macOS build matrix for the binary; CI artifact strategy.
