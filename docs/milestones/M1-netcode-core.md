# M1 — Netcode Core

**Status:** blocked ⚠️ (gate run 2026-06-13, FAILED tick budget — see Evidence)

**Objective:** A working authoritative replication core: the hardest, highest-risk part of the project. Get this right and everything else is "just gameplay."

## Scope

- Fixed **30 Hz** authoritative server tick (config value).
- Client → server **input command frames** (movement/look/fire/actions) with client tick + sequence numbers.
- Server → client **delta-compressed snapshots** of entities within the client's **interest set**.
- **Interest management** — spatial grid / area-of-interest culling (first-class deliverable, not an add-on).
- **Bandwidth controls** — delta vs last-acked snapshot, field quantization (pos/angles), per-entity priority/rate limiting.
- **Client prediction & reconciliation** — predict local pawn, replay unacked inputs against authoritative state.
- **Interpolation** — remote entities rendered with an interpolation delay buffer.
- **Lag compensation** — server rewinds hit checks to shooter's view time (interface in place; consumed by M2 gunplay).
- ENet **channels**: reliable (events/spawns) vs unreliable-sequenced (snapshots/input).
- A single replicated **test pawn** to exercise all of the above.
- **Telemetry** counters from day one: tick time, bandwidth/player, entity counts, packet loss.

## Gate

Bot fleet sustains **128 connected pawns** moving randomly at a stable **30 Hz** on one Linux host, within a defined CPU and bandwidth-per-player budget (record the budget here when set). **Do not pass this gate loosely — it de-risks the entire project.**

## Evidence (gate run 2026-06-13)
- Stress run command: `ci/m1_load_test.sh` (server + 128 bots, headless, single Linux host, 30s run)
- Final telemetry at full population (128 players):
  ```
  [telemetry] players=128 tick_mean=71.29ms tick_p99=80.79ms peak=64077B/s agg=64.0Mbit/s starv=491
  ```
- Numbers vs. budget:
  - Server tick mean: **71.29 ms** (budget < 33.3 ms) — **FAIL**, ~2.1x over budget
  - Server tick p99: 80.79 ms
  - Peak per-client downstream: 64,077 B/s (~64 KB/s — within the ≤64 KB/s mean target, but measured under a server that is not holding tick rate)
  - Aggregate server out: 64.0 Mbit/s (well within < 250 Mbit/s budget)
  - Starvation count: 491 (non-zero — clients missing snapshot updates)
- Result: `M1 GATE: FAIL (mean tick 71.29 >= 33.3)`. Bot fleet successfully connected and the telemetry pipeline works end-to-end (players=128 reached), but per-tick server CPU cost at 128 players is roughly double the 30 Hz budget. A repeat run (not the recorded gate, exploratory) showed steady-state mean tick ~66-69ms at 128 players with the player count subsequently dropping (128→119→106) as the server fell behind and connections timed out, confirming this is a genuine tick-cost issue (likely O(n^2) or per-pair work in interest management / snapshot building) rather than a one-off spike.
- Owner: claude (M1 final task)
- Follow-up: M1's replication/interest-management/snapshot-building hot path needs profiling and optimization to bring tick_mean under 33.3ms at 128 players before this gate can be considered a true PASS. Tracked as a carry-over item; do not start gameplay-heavy M2 work that further raises per-tick cost until this is addressed.

## Spec (approved-pending-review)
- [`docs/specs/m1-netcode-core.md`](../specs/m1-netcode-core.md) — one consolidated doc covering wire protocol, replication (snapshots + prediction/reconciliation/interpolation), and interest management.

## Budgets (gate pass/fail)
- Server tick: mean step **< 33.3 ms** at 128 players (log p99).
- Per-client downstream: target **≤ ~64 KB/s mean**, alarm above **~128 KB/s sustained**.
- Server aggregate out: **< ~250 Mbit/s** at 128p (~25% of 1 Gbit).
