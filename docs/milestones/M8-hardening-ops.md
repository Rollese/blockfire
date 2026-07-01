# M8 — Hardening & Ops

**Status:** in-progress — **P1 (stress harness + runbooks) done ✅ 2026-07-01**; P2 (telemetry schema) + P3 (server ops) remain · Spec: [`docs/specs/m8-hardening-ops.md`](../specs/m8-hardening-ops.md)

> **P1 — one-command stress run + runbooks (satisfies the literal gate) — DONE 2026-07-01 (game2).**
> `docker/stress.sh` (canonical operator entrypoint, built on the new shared `docker/_gate_lib.sh`
> = launch/wait/scrape/verdict) spins server + 128 bots, plays a full Conquest match, prints a
> PASS/FAIL verdict + telemetry summary. **`STRESS GATE: PASS`**: `winner=1 elapsed=274s peak
> tick=20.53ms<33.3 agg=13.6Mbit/s players=128 kills=10`, bot-perf `ai_us_mean=996µs` (scales to
> 128); `docker/srvlog-m8stress-20260701-232731.log`. Runbooks: `docs/runbooks/running-a-stress-test.md`
> + `docs/runbooks/reading-telemetry.md` (full `[telemetry]` field glossary). **P2/P3 below.**

> **P2 — telemetry schema + export — DONE 2026-07-01.** `docs/specs/telemetry.md` = the
> authoritative `[telemetry]` schema-of-record (stable key order, append-only field contract).
> Added `pktloss` — mean per-peer ENet packet loss % (`Telemetry.mean_packet_loss_pct`, unit-tested;
> server reads `peer.get_statistic(PEER_PACKET_LOSS)` per client) — the one genuinely-missing
> health field. Emit validated (server boots, line carries `pktloss=0.00%`, no format error; suite
> 954/0). The opt-in `--telemetry-json` NDJSON sink is specced but **deferred (YAGNI — no dashboard
> consumer yet)**. **P3 (server-ops: config file + graceful shutdown + adaptive degradation) remains.**

**Objective:** Make the server and bot fleet operable, observable, and repeatably stress-testable.

## Scope
- Server **metrics/telemetry** export (tick time, bandwidth/player, entity counts, packet loss) → dashboard or structured logs.
- Crash recovery, graceful shutdown, server config + hot-reloadable match settings (player cap, tick rate, map rotation).
- **Docker**: `docker/Dockerfile.server`, `docker/Dockerfile.bots`, `docker/compose.stress.yml`.
- Bot-fleet orchestration for large stress runs.
- `docs/runbooks/`: run server, run bot fleet, run a stress test, read telemetry.
- Define **graceful degradation** under overload (shed snapshot rate to distant entities rather than collapse).

## Gate
A documented **one-command stress run** spins a server + 128 bots in Docker, telemetry shows 30 Hz held within budget, and a full Conquest match completes.

```
docker compose -f docker/compose.stress.yml up   # 1 server + 128 bots
```

## Specs required
- `docs/specs/telemetry.md`, `docs/specs/server-ops.md`
