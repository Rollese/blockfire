# M1 — Netcode Core

**Status:** todo · **Blocked by:** M0 gate

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

## Evidence (fill in when gate passes)
- Budget targets (CPU %, KB/s per player):
- Stress run command + telemetry output:
- Date / owner:

## Spec (approved-pending-review)
- [`docs/specs/m1-netcode-core.md`](../specs/m1-netcode-core.md) — one consolidated doc covering wire protocol, replication (snapshots + prediction/reconciliation/interpolation), and interest management.

## Budgets (gate pass/fail)
- Server tick: mean step **< 33.3 ms** at 128 players (log p99).
- Per-client downstream: target **≤ ~64 KB/s mean**, alarm above **~128 KB/s sustained**.
- Server aggregate out: **< ~250 Mbit/s** at 128p (~25% of 1 Gbit).
