# M8 — Hardening & Ops — Spec (brainstorm-of-record)

Status: **active** · Milestone: [`M8-hardening-ops.md`](../milestones/M8-hardening-ops.md) · Authored 2026-07-01

Make the dedicated server and bot fleet **operable, observable, and repeatably
stress-testable**. This is largely consolidation + hardening of infrastructure that already
exists piecemeal (rich `[telemetry]` log line; a parametrized Docker `docker-compose.yml`;
~13 per-milestone `run-*-gate.sh` scripts; CLI-arg config), not greenfield.

## Guiding decisions (defaults, BattleBit-pragmatic)

- **Structured logs, not a metrics stack.** This is a LAN game with no ops infrastructure. The
  observability surface is the existing one-line-per-window `[telemetry] key=value …` server
  log (machine-parseable already), formalized with a documented schema + an **opt-in NDJSON
  sink** for anyone who wants to graph it. No Prometheus/HTTP-exporter dependency (YAGNI).
- **Crash *recovery* = graceful shutdown + clean match teardown.** Full mid-match state
  snapshotting/restore is YAGNI for a LAN dedicated server — a dead match simply restarts (the
  fleet/orchestrator relaunches). We harden the *shutdown* path and match lifecycle, not state
  persistence.
- **Degradation reuses the existing snapshot knobs.** M3 already bounded the tick hot path with
  `SNAPSHOT_STRIDE` (send cadence) + `MAX_SNAPSHOT_ENTITIES` (enemy-prioritized relevance cap).
  Graceful degradation makes these **adaptive** (react to measured `tick_mean`) instead of
  static consts — no new replication machinery.

## Phasing (each independently gateable; own plan per phase)

### P1 — Stress harness + runbooks  *(satisfies the literal M8 gate; no game-code change)*
- `docker/stress.sh` (+ `docker/compose.stress.yml` if a distinct compose profile helps): **one
  command** → dedicated server + 128 bots in Docker, runs a full Conquest match to a winner,
  then prints a PASS/FAIL verdict + a telemetry summary (peak tick, agg bw, winner, elapsed,
  bot-perf). Server pinned to P-cores; bots on the rest (game2 defaults).
- Factor the shared launch/wait/scrape/verdict logic out of the per-milestone gate scripts into
  a reusable **`docker/_gate_lib.sh`**; re-point `run-m7.5-gate.sh` (and, opportunistically, the
  newest gates) at it to prove the library. Do **not** rewrite every historical gate script.
- `docs/runbooks/running-a-stress-test.md` — the one-command run, env knobs, reading the verdict.
- `docs/runbooks/reading-telemetry.md` — the `[telemetry]` field glossary + how to spot budget
  breaches / starvation.
- **Gate:** `docker/stress.sh` on game2 → valid winner, peak tick < 33.3 ms, `[bot-perf]` present,
  match via tickets not time; persisted `srvlog`.

### P2 — Telemetry schema + export
- `docs/specs/telemetry.md` — canonical field glossary for the `[telemetry]` line; every field
  documented (units, source, budget interpretation). Add **ENet packet-loss** (per-peer round-up)
  and confirm entity counts (players/alive/struct present; add veh/proj if missing from the line).
- Opt-in `--telemetry-json=<path>` → append one **NDJSON** record per window (same fields) for
  dashboards. Off by default (zero cost when unset).
- Pure formatter (`shared/telemetry.gd` or a helper) → unit-tested (schema stability + JSON
  round-trip). **Gate:** unit tests green; a stress run emits a valid NDJSON file parseable by a
  one-liner.

### P3 — Server ops: config + shutdown + adaptive degradation
- `docs/specs/server-ops.md`.
- **Config file** (`data/server_config.json`): match settings (player cap, tick rate, tickets,
  time limit, **map rotation** list). Loaded at boot; **CLI args override file**; file absent →
  current CLI/const defaults (back-compatible). Map rotation advances between matches.
- **Graceful shutdown**: SIGTERM → stop accepting joins, end/abort the current match cleanly,
  disconnect peers with a reason, flush telemetry, exit 0. **[2026-07-01: investigated — NOT
  feasible in pure GDScript on headless Godot 4.6.** POSIX signals are not delivered as
  `NOTIFICATION_WM_CLOSE_REQUEST` without a display server, and GDScript exposes no signal-handler
  API; a `set_auto_accept_quit(false)` + `_notification` handler was verified inert (process took
  the OS default, exit 143/130). Needs a **native GDExtension signal handler** or an **admin
  control-channel `SHUTDOWN` command** (ties to the M7.5 admin-allowlist, deferred). **Deferred** —
  benign for a LAN server (no persistence; `docker stop` SIGKILLs after grace).]
- **Adaptive graceful degradation**: when windowed `tick_mean` breaches a high-water mark, raise
  `SNAPSHOT_STRIDE` / lower the relevance cap by one step; restore (hysteresis) once recovered.
  Log each transition (`[degrade] …`). Pure decision helper (input tick_mean + current level →
  next level) → unit-tested; wired into the tick loop behind the existing knobs.
- **Gate:** unit tests (config precedence, rotation advance, degradation ladder + hysteresis,
  shutdown path); a 128-bot stress run holds budget with adaptive degradation enabled and still
  reaches a winner; SIGTERM mid-match exits cleanly (no orphaned peers / error spew).

## Non-scope (YAGNI)
- Prometheus / HTTP metrics endpoint / Grafana. (Structured logs + opt-in NDJSON only.)
- Mid-match state persistence / hot crash-restore. (Dead match → relaunch.)
- Per-peer bandwidth throttling beyond the snapshot cadence knobs.
- Rewriting all historical `run-*-gate.sh` scripts (only factor the shared lib + re-point the
  newest; leave closed-milestone gates as recorded evidence).
- Kubernetes / multi-host orchestration (single-host Docker fleet is the target).

## Sequencing
P1 → P2 → P3. P1 is pure ops (no game code) and closes the literal gate; P2 is additive
(server telemetry emit + a doc); P3 touches the tick hot path (degradation) and match lifecycle
and is gated hardest. Each phase: `writing-plans` → `subagent-driven-development` → gate, TDD per
task, per AGENTS.md.
