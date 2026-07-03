# Spec — Server Ops: Config File + Map Rotation (spec-of-record)

Status: **active** (M8-P3, landed 2026-07-03) · Milestone: [`M8-hardening-ops.md`](../milestones/M8-hardening-ops.md) ·
Brainstorm: [`m8-hardening-ops.md`](m8-hardening-ops.md) §P3 · Plan: [`2026-07-03-m8-p3-config-map-rotation.md`](../plans/2026-07-03-m8-p3-config-map-rotation.md)

Make the dedicated server operable without editing code or shell scripts: an optional JSON config
file for match settings, and a **map-rotation mode** that turns the single-match-then-exit server
into a persistent multi-match loop. Both are strictly additive — **no config file and no rotation
list means exactly today's behavior** (one match on the default/`--map` map, exit 0 at match end),
which every `docker/*gate*.sh` / `ci/*.sh` script depends on.

## Config file

`data/server_config.json` — optional, loaded once at boot by `server/config.gd` (`ServerConfig`,
the repo `{ok, config, error}` load contract). `--config=<path>` overrides the location (absolute
paths allowed — used by the rotation smoke). Copy [`data/server_config.example.json`](../../data/server_config.example.json)
to get started; the real `data/server_config.json` is **gitignored** (a committed rotation config
would make the server never exit and hang every gate script).

| Key | Type | Default | Notes |
|---|---|---|---|
| `port` | int | 27015 | ENet listen port. |
| `max_players` | int | 128 | join cap; config-file-only (no CLI flag exists). |
| `tickets` | int | map default | starting tickets per team. |
| `time_limit` | float s | map default | match time fail-safe. |
| `maps` | array of strings | `[]` | map basenames from `maps/*.json` (e.g. `"conquest_town"`). **Non-empty ⇒ rotation mode** (below). |
| `degrade_high_ms` / `degrade_low_ms` | float ms | 30 / 26 | adaptive-degradation band; defaults live in `server/degrade.gd` (`HIGH_MS`/`LOW_MS`). Inverted band (low ≥ high) → warning + safe defaults. |

- **Precedence: CLI > file > built-in default** (`ServerConfig.resolve`, pure + unit-tested).
- **Absent file = ok + defaults** (the file is optional). **Malformed JSON or a non-dict root =
  loud boot failure, exit 1** — an operator-authored config that doesn't parse must not silently
  fall back to defaults mid-LAN-party.
- Unknown keys and wrong-typed keys are **warned and dropped** (the rest of the file still applies).

## Map rotation

**Activation:** rotation is active iff the config `maps` list is non-empty **and** no `--map` CLI
override is given. `--map` pins a single map, single match, exit-on-end — today's gate semantics,
unconditionally. Boot prints `[server] map rotation active: <list>`.

**Match boundary** (in rotation mode, at match end; order as in `_rotate_match`):
1. The existing 60-tick drain runs (`MATCH_END_DRAIN_TICKS`) — the final reliable `MATCH_STATE`
   with `over=true` has already been broadcast, so clients see the result.
2. The rotation index advances (wraps around at the end of the list; a single-entry list loops the
   same map) and the server logs `[server] match complete — rotating to <map>`.
3. `NetHost.disconnect_all()` politely disconnects every peer (queued reliable sends flush first).
4. `_reset_match_state()` wipes **every** match-scoped var (sim/world, clients, squads, stats,
   ordnance, reliable lists, degrade level, perf buckets — the full var block is audited; boot-scoped
   state like the net host, catalogs, resolved config and rolling telemetry survives).
5. `_start_match()` loads the next map and the server keeps listening — same port, same net host.

**Failure mode:** a rotation entry pointing at a missing/broken map is an operator config error →
`push_error` + exit 1 (a silently-dead persistent server is worse than a loud exit).

**Client story:** disconnected clients reconnect; `WELCOME` already carries the map name and the
rendered client adopts it (`client_main.gd _handle_welcome` — `[client] adopting server map`). No
wire change was needed. **Automatic client reconnect UX is a known gap** — an M7 polish follow-up;
today a human relaunches/reconnects manually (bots reconnect via their driver loop).

## Explicitly out of scope (and why)

- **`tick_rate`** — deliberately not a config key. `SimLoop.DT` is a compile-time sim constant
  (1/30); a runtime tick rate is a sim-wide change (prediction, ballistics, timers) with no current
  need. YAGNI.
- **Hot reload** — the config is read once at boot. Restart to apply (a LAN server; restarts are cheap).
- **SIGTERM graceful shutdown** — investigated 2026-07-01, **not feasible in pure GDScript** on
  headless Godot 4.6 (no POSIX signal delivery); needs a GDExtension signal handler or an admin
  control-channel command. Deferred — see [`m8-hardening-ops.md`](m8-hardening-ops.md) §P3.

## Evidence

- Unit tests: `tests/server_config_test.gd` (12 — load contract, validation, precedence, rotation
  resolution), `tests/net_disconnect_all_test.gd` (2, real loopback ENet),
  `tests/server_configure_test.gd` (4, fixture-level `configure()`), `tests/server_rotation_test.gd`
  (3 — full state reset, wrap-around, fresh vehicles). Full suite **1080 run / 0 failed**.
- Integration smoke: `ci/m8_p3_rotation_test.sh` — botless 2-map rotation
  (`conquest_dev_arena` ↔ `conquest_proving_grounds`, 8 s time limit) → `M8-P3 ROTATION SMOKE: PASS (matches=2,
  rotations=2)` in ~20 s; run 3× green.
- 128-bot stress no-regression gate: **PASS 2026-07-03** on game2 (`winner=1 elapsed=246s
  peak tick=16.74ms<33.3 agg=13.3Mbit/s players=128`, 0 script errors;
  `docs/gate-evidence/20260703-121729-stress.txt`, srvlog `docker/srvlog-stress-20260703-121729.log`)
