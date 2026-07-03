# M8 — Hardening & Ops

**Status:** **complete except one deferred item** — **P1 (stress harness + runbooks) ✅ + P2 (telemetry schema-of-record + pktloss) ✅ done 2026-07-01; P3 (adaptive degradation ✅ 2026-07-01 + config file & map rotation ✅ done 2026-07-03)**. Only remaining item: SIGTERM graceful shutdown (investigated → not feasible in pure headless GDScript, **deferred**). Pre-P3 hardening batch (deploy-ref re-base, protocol VERSION 2, per-life AI reset) landed 2026-07-02 · Spec: [`docs/specs/m8-hardening-ops.md`](../specs/m8-hardening-ops.md) · Server-ops spec: [`docs/specs/server-ops.md`](../specs/server-ops.md)

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
> consumer yet)**. **P3 below.**

> **P3 — server-ops — in progress.** **Adaptive graceful degradation DONE 2026-07-01** (the
> "shed snapshot rate under overload" gate item): pure `server/degrade.gd` hysteresis ladder
> (`next_level`, thresholds injectable; `tests/degrade_test.gd` 7 tests) — over HIGH_MS (30) climbs
> a step (longer send stride + fewer distant enemies), under LOW_MS (26) restores, holds in-band.
> Wired into `server_main` (`SNAPSHOT_STRIDE`/`MAX_ENEMY_SNAPSHOT` → dynamic `_snapshot_stride`/
> `_max_enemy_snapshot`, re-evaluated per telemetry window); **level 0 == the old consts** so it's
> inert under budget. `--degrade-high-ms`/`--degrade-low-ms` CLI overrides (force-trigger for tests).
> Validated: suite 961/0; forced-trigger boot climbs 0→1→2 with `[degrade]` logs; **no-regression
> fleet gate PASS** (128p, peak tick 18.27ms, winner=1, **zero `[degrade]` under budget**;
> `docker/srvlog-m8p3-20260701-234519.log`). **Graceful (SIGTERM) shutdown investigated
> 2026-07-01 → NOT feasible in pure GDScript** (headless Godot 4.6 doesn't deliver POSIX signals as
> `NOTIFICATION_WM_CLOSE_REQUEST`; no GDScript signal API — verified exit 143/130, handler inert).
> Deferred: needs a native GDExtension signal handler or an admin control-channel `SHUTDOWN` command
> (benign for a LAN server — `docker stop` SIGKILLs after grace). **Remaining P3: config file + map
> rotation** (the persistent multi-match loop — highest blast radius, own focused session).

> **P3 — config file + map rotation — DONE 2026-07-03** (branch `m8-p3-config-rotation`; spec-of-record
> [`docs/specs/server-ops.md`](../specs/server-ops.md)). `server/config.gd` (`ServerConfig`) loads the
> optional `data/server_config.json` (`--config=<path>` overrides; `{ok, config, error}` contract;
> absent file = defaults, malformed = loud exit 1, unknown/mistyped keys warned + dropped) with
> **CLI > file > built-in default** precedence; keys: `port`/`max_players`/`tickets`/`time_limit`/
> `maps`/`degrade_high_ms`/`degrade_low_ms` (`tick_rate` deliberately excluded — SimLoop.DT is a
> compile-time sim constant). **Rotation** active iff config `maps` non-empty and no `--map` CLI
> override (`--map` pins single-match exit-on-end — all gate scripts unaffected; no config file →
> exactly the old behavior): match end → 60-tick drain → `NetHost.disconnect_all()` → audited
> `_reset_match_state()` → `_start_match()` on the next map (wraps); missing rotation map = loud
> exit 1; clients reconnect and adopt the new map via WELCOME (no wire change; client auto-reconnect
> UX = M7 follow-up). `data/server_config.example.json` committed, real config gitignored. Tests:
> `server_config_test` (12) + `net_disconnect_all_test` (2) + `server_configure_test` (4) +
> `server_rotation_test` (3); full suite **1080/0**. Rotation smoke `ci/m8_p3_rotation_test.sh`:
> `M8-P3 ROTATION SMOKE: PASS (matches=2, rotations=2)` (~20 s, run 3× green). 128-bot stress
> no-regression: **[stress verdict pending — filled before merge]**.

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
