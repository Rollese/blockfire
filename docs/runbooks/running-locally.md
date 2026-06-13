# Runbook: running locally

Requires **Godot 4.6.x** on `PATH` (verified on 4.6.3). Running from source needs no export presets — those are only for the Docker/CI builds (M8).

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
godot --path . -- --connect=127.0.0.1 --port=27015 --name=YourName
```
(Add `--headless` to run a connection-only client without a window — useful for tests.)

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

## Prerequisites for later milestones (not yet installed here)

- **Docker** — for the bot fleet / stress runs (M8). Not installed in the current dev box.
- **Rust toolchain** — only if M1 profiling forces a GDExtension hot path (ADR-0001 / future ADR-0003). Not needed for M0–M3.
