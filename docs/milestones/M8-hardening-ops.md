# M8 — Hardening & Ops

**Status:** todo · **Blocked by:** M7 gate

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
