# Runbook — Running a Stress Test (one command, 128 bots)

The M8 stress harness spins the dedicated server + a 128-bot fleet in Docker on a single host,
plays a full Conquest match, and prints a PASS/FAIL verdict with a telemetry summary. This is the
canonical operator entrypoint and the **M8 gate**.

## Prerequisites
- Run on **game2** (14900KS / CachyOS, 32 threads) — the dev + gate host. Docker installed.
- Nothing else contending the pinned cores. The full unit suite should be green first
  (`godot --headless --path . -- --test`).

## One command

```bash
cd docker
SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./stress.sh
```

- Server is pinned to **P-cores only** (logical 0–15; 16–31 are slower E-cores — see AGENTS.md §8).
- `BOT_REPLICAS × BOT_COUNT = 128` bots across 16 processes (avoids single-process input starvation).
- Builds images on first run (cached after), brings the fleet up, waits for `[match] OVER`, saves
  the full server log to `docker/srvlog-stress-<ts>.log`, prints the verdict, and tears down.

## Verdict criteria (M8 gate)
`STRESS GATE: PASS` requires all of:
- a valid Conquest winner (`0` or `1`) — the match completes;
- peak-window `tick_mean` **< 33.3 ms** (30 Hz held within budget);
- match ended via tickets, not the `TIME_LIMIT` fail-safe;
- `[bot-perf]` telemetry present (bot-driver CPU scaled to 128);
- match not inert (`cap_events ≥ 1` **or** `kills ≥ 1`).

## Tunables (env)
| Var | Default | Notes |
|---|---|---|
| `MAP` | `conquest_proving_grounds` | comfortable tick budget. Use `conquest_town` for the **dense high-load** variant (peak snapshot + combat + destruction cost; rides ~28–30 ms). |
| `TICKETS` | compose default | lower = shorter match; higher = longer (more combat time). |
| `TIME_LIMIT` | 900 | match time fail-safe (s). |
| `TICK_BUDGET_MS` | 33.3 | pass threshold for peak tick. |
| `MAX_WAIT` | 720 | how long to wait for a winner (s) before FAIL. |
| `BOT_REPLICAS` / `BOT_COUNT` | 16 / 8 | fleet shape. Raise `BOT_REPLICAS` if `starv` is high. |
| `SERVER_CPUS` / `BOTS_CPUS` | — | taskset core pins passed to compose. |
| `LABEL` | `stress` | srvlog filename tag. |

## Reading the result
The summary line reports peak tick, aggregate bandwidth, peak players, kills, and bot-driver
`ai_us_mean`. For a full field glossary and health interpretation see
[`reading-telemetry.md`](reading-telemetry.md). The persisted `srvlog-*.log` is the recorded evidence.

## Persistent server + map rotation (M8-P3)

Outside the gate scripts, a long-running server can play matches back-to-back via a config file
(spec: [`docs/specs/server-ops.md`](../specs/server-ops.md)). Copy
`data/server_config.example.json` to `data/server_config.json` (gitignored) or point at any path
with `--config=<path>`:

```json
{
  "maps": ["conquest_town", "conquest_proving_grounds", "conquest_arena_buildings"],
  "tickets": 300,
  "time_limit": 1800
}
```

```bash
godot --headless --path . -- --server --config=/abs/path/server_config.json
```

A non-empty `maps` list (and no `--map` CLI override) enables rotation: at match end the server
disconnects everyone, resets all match state, and starts the next map — **it never exits**.
CLI args still win over the file; `--map` pins one map + exit-on-end (gate semantics).

> **⚠ Never place a rotation config on a gate host.** Every gate/stress script waits for the
> server to exit at match end — a `data/server_config.json` with a `maps` list would make them
> hang until `MAX_WAIT`. The real config file is gitignored for exactly this reason.

## Cross-host / feature gates
- Bots-here-server-elsewhere and other topologies: see [`docker/README.md`](../../docker/README.md).
- Per-feature assertions (melee, FOB, ballistics, …) live in the milestone `docker/run-*-gate.sh`
  scripts. `stress.sh` builds on the shared `docker/_gate_lib.sh` (launch/wait/scrape/verdict);
  new gates should source it too rather than copy the boilerplate.
