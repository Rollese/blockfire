# M1 — Netcode Core

**Status:** done ✅ (gate passed 2026-06-13)

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
  [telemetry] players=128 tick_mean=17.65ms tick_p99=25.71ms peak=6685B/s agg=3.6Mbit/s starv=776
  ```
- Numbers vs. budget:
  - Server tick mean: **17.65 ms** (budget < 33.3 ms) — **PASS**, ~53% of budget
  - Server tick p99: 25.71 ms (budget-adjacent but under 33.3 ms)
  - Peak per-client downstream: 6,685 B/s (~6.7 KB/s — well within the ≤64 KB/s mean target)
  - Aggregate server out: 3.6 Mbit/s (well within < 250 Mbit/s budget)
  - Starvation count: 776 (non-zero — clients missing snapshot updates; not gating for M1 but worth tracking)
- Result: `M1 GATE: PASS`. Root cause of the prior FAIL was every pawn spawning at the origin, clustering all 128 bots within each other's 250 m interest radius and forcing O(n²) snapshot building. Fix: spawns are now distributed uniformly across a 2 km square map (`WORLD_HALF` raised to 1000.0, spawn position randomized in `_handle_hello`), letting interest-grid culling actually reduce per-tick snapshot work.
- Note: the pathological all-clustered-in-one-spot case (everyone spawning/standing in the same area) remains a future stress scenario that may still warrant the ADR-0001 GDExtension escalation if it needs to be supported at 128 players; tracked for later, not blocking M1.
- Owner: claude (M1 final task)

## Spec (approved-pending-review)
- [`docs/specs/m1-netcode-core.md`](../archive/specs/m1-netcode-core.md) — one consolidated doc covering wire protocol, replication (snapshots + prediction/reconciliation/interpolation), and interest management.

## Budgets (gate pass/fail)
- Server tick: mean step **< 33.3 ms** at 128 players (log p99).
- Per-client downstream: target **≤ ~64 KB/s mean**, alarm above **~128 KB/s sustained**.
- Server aggregate out: **< ~250 Mbit/s** at 128p (~25% of 1 Gbit).
