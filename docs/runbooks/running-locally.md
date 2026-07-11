# Runbook: running locally

Requires **Godot 4.7.x** on `PATH` (verified on 4.7.stable). Running from source needs no export presets — those are only for the Docker/CI builds (M8).

> First run on a fresh checkout: import resources once so `.godot/` is built:
> ```
> godot --headless --path . --import
> ```

## Dedicated server (headless)

```
godot --headless --path . -- --server --port=27015
```
Authoritative, 30 Hz, up to 128 players. Runs until killed (Ctrl-C).

## Client

```
godot --path . -- --connect=127.0.0.1 --port=27015 --name=YourName --map=<same map as the server>
```
(Add `--headless` to run a connection-only client without a window — useful for tests.)

> **Pass `--map` to the client too** when the server runs a non-default map — the client builds
> roads/props locally and desyncs visually otherwise (see `running-client.md`). Full rendered-client
> flags, QA `--*-test` flags, and screenshot recipes: `docs/runbooks/running-client.md`.

## Bot driver

```
godot --headless --path . -- --bots --bot-count=8 --connect=127.0.0.1 --port=27015
```
Spawns N bots in one process, each a real client connection sharing the same protocol.

## M0 connect smoke test (the M0 gate)

```
ci/connect_smoke_test.sh
```
Starts a server, a client, and one bot; asserts the handshake completes for both. Exits non-zero on failure. Override `GODOT` or `PORT` via env vars.

## Bigger runs

- **Docker fleet / stress (installed + canonical on game2):** `cd docker && ./stress.sh` for the
  one-command 128-bot stress run, or a per-milestone `run-*-gate.sh`. How-to + interpretation:
  `docs/runbooks/running-a-stress-test.md`, `docs/runbooks/reading-telemetry.md`.
- **Rust toolchain** — needed only to rebuild the M6 Opus voice GDExtension (`native/voice_opus/`);
  the sim/netcode never required the ADR-0001 GDExtension escalation.
