# Dockerized server + bot fleet (isolated M3 gate / M8 fleet bootstrap)

Purpose: run the M3 Conquest gate with the **dedicated server isolated from the bot fleet**, so
the single-threaded server tick runs uncontended. On the dev laptop the co-located 128-bot
driver thermally throttles the chip (server tick 50–106 ms vs the 33.3 ms budget); the fix is to
keep the server on its own (cool, uncontended) core/host and run the bots elsewhere. See
[issue #1](https://github.com/Rollese/blockfire/issues/1) and `docs/milestones/M3-conquest-squads.md`.

This is the **run-from-source** setup: the image ships the Godot binary and runs the project
directly, so it works **today** with no export presets. (The leaner export-based approach is
deferred — see "M8 production variant" at the bottom.)

> **Status:** authored but **not yet run** — Docker isn't installed on the dev laptop. Validate on
> the unraid box (or the future 14900K dedi) and record the result in the milestone doc.

## Files
- `Dockerfile` — headless Godot 4.6 image; runs the project as server **or** bots (role via `command`).
- `docker-compose.yml` — `server` + `bots` services with `full` / `bots` profiles.
- `run-gate.sh` — one-command single-host **M3** gate (server + fleet in separate containers, asserts PASS/FAIL).
- `run-m4-gate.sh` — same topology, **M4 Phase-1 (Building)** assertions: the M3 criteria PLUS peak `struct>=1`, sum `bld>=1`, sum `blk>=1`, and a `structures synced` line in the bot logs. Building is always-on in the server, so it shares this compose. Run it the same way: `SERVER_CPUS=0,1,14,15 BOTS_CPUS=2-13,16-27 ./run-m4-gate.sh`.
- `entrypoint.sh` — `exec`s godot; honours `BOOT_DELAY` so the fleet waits for the server.

## Prerequisites
- Docker Engine + Compose v2 (`docker compose …`).
- Network reach: bot containers must reach the server on `PORT/udp` (ENet is **UDP**).
- **Godot binary:** the image downloads `Godot_v${GODOT_VERSION}_linux.x86_64` from GitHub releases
  (default `GODOT_VERSION=4.6-stable`). If 4.6 isn't published at that URL, override:
  `docker build --build-arg GODOT_URL=<url> …`, or drop a binary in the context and `COPY` it
  instead of the `curl` step. The project's `config/features` pins **4.6** — match it.

## The three test scenarios (run them cheapest-first)

### 1. Cheapest decisive test — server on the laptop, bots on unraid
Tests whether *isolation alone* gets the laptop server under budget (no new hardware needed).

On the **laptop** (bare metal, the server runs alone and stays cool/boosted):
```bash
godot --headless --path . -- --server --port=27240 --tickets=80 --time-limit=600 | tee /tmp/m3srv.log
```
On **unraid** (the bot fleet, 128 bots across 4 processes):
```bash
cd docker
SERVER_HOST=<laptop-LAN-ip> BOTS_CPUS=0-27 \
  docker compose --profile bots up --build
```
Then read the **laptop** server log:
```bash
grep -E '\[match\] OVER|tick_mean' /tmp/m3srv.log | tail
```
Pass = `[match] OVER` with a valid winner, `cap_events>=1`, `elapsed<600`, and the peak
`tick_mean < 33.3 ms`. If the laptop server passes here → **M3 closes with zero new hardware.**

### 2. All-on-unraid (single host, server pinned to isolated cores)
If scenario 1 still breaches, run everything on the unraid **W-2275** with the server pinned to its
own physical core (server-class cooling = no throttle, sustained clock):
```bash
cd docker
# Inspect topology first (`lscpu -e`) and pick a disjoint split. Example for 28 logical CPUs:
SERVER_CPUS=0-1 BOTS_CPUS=2-27 ./run-gate.sh
```
Expect `M3 DOCKER GATE: PASS`. This is the M8-aligned production shape (server + container fleet).

### 3. Future best — server on the 14900K dedi, bots on unraid
When the dedi is ready, make it the **server host** (highest sustained single-thread = lowest tick,
most headroom for M4/M5) and keep unraid as the **fleet**. Same as scenario 1 with the dedi as the
server box (or run the server in its own container there).

## Tunables (env vars)
| var | default | meaning |
|---|---|---|
| `PORT` | `27240` | server UDP port |
| `TICKETS` | `80` | starting ticket pool (gate-tuned for a prompt finish) |
| `TIME_LIMIT` | `600` | match time fail-safe (s) |
| `BOT_COUNT` | `32` | bots **per** container |
| `BOT_REPLICAS` | `4` | bot containers (4×32 = 128) |
| `SERVER_CPUS` | `0-1` | cpuset for the server (give it an isolated physical core) |
| `BOTS_CPUS` | `2-27` | cpuset for the fleet (disjoint from the server) |
| `SERVER_HOST` | `server` | where bots connect (`bots` profile: set to the server's IP) |
| `BOOT_DELAY` | `10` | seconds the fleet waits for the server before connecting |

## Reading results
- Server telemetry/`[match]` lines go to the **server** container's stdout:
  `docker compose --profile full logs server | grep -E '\[telemetry\]|\[match\]'`.
- The gate metric is the peak-window `tick_mean` (the assertion budget is 33.3 ms).
- High `starv=` means the fleet can't feed inputs fast enough — raise `BOT_REPLICAS` (more
  processes); it should be ~0 when the fleet has enough cores.

## Notes / gotchas
- **Single-thread is the lever.** More cores help the *fleet*, not the server tick. Pin the server
  to the best-clocked isolated core; don't expect core count to lower the tick.
- ENet is **UDP** — port publishing and any firewall rules must allow UDP on `PORT`.
- `deploy.replicas` is honoured by `docker compose up` (Compose v2). If you're on the old
  `docker-compose` (v1), use `--scale bots=$BOT_REPLICAS` instead.
- A breach that persists on a **cool, uncontended, fast** box would be the real signal to consider
  the ADR-0001 GDExtension escalation — not before.

## M8 production variant (export-based) — deferred
The earlier `docker/` stubs (now retired) shipped a **headless Linux export** of the project
(`build/server/blockfire_server`, `build/bots/blockfire_bots`) copied into a slim image, rather than
the whole engine. That's leaner and the right production shape, but it needs the Godot **export
presets** (an M8 deliverable per ADR-0002) which don't exist yet. When M8 builds those presets, the
production images become: `debian:bookworm-slim` + `COPY build/<role>/ /app/` + a tiny runtime-libs
set (`libfreetype6 ca-certificates`) + an entrypoint that runs the exported binary with the same
`-- --server` / `-- --bots …` flags this run-from-source setup uses. Keep this compose's
profiles/topology/env interface so the M8 swap is binary-only.
