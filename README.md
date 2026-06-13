# Blockfire

Internal codename for a lightweight, large-scale (up to **128 players**) low-poly FPS built in **Godot 4.6**, inspired by *BattleBit Remastered*. v1 ships a single game mode: **Conquest**.

> Internal project. The dedicated server and bot-driver builds are **not** for public release.

## Components

| Component | Path | Description |
|---|---|---|
| Shared core | `shared/` | Deterministic sim, wire protocol, gameplay rules. Linked by all binaries — the single source of truth so client/server/bot never drift. |
| Client | `client/` | Player-facing game: rendering, input, UI, client-side prediction + interpolation. |
| Dedicated server | `server/` | Headless, authoritative, Linux-only. 30 Hz tick. |
| Bot driver | `bots/` | Headless Godot build simulating many bots/process. Reuses `shared/`. Dockerized fleet for stress + playtesting. |

## Architecture in one line

The **server is authoritative**. Clients (and bots) send input commands; the server simulates at a fixed 30 Hz and emits delta-compressed, interest-managed snapshots. Clients predict locally and reconcile.

## Getting started

- **Engine:** Godot 4.6.x (verified on 4.6.3).
- **Run a headless server:** see `docs/runbooks/`.
- **Run the bot fleet / stress test:** see `docs/runbooks/`.

## For agents working on this project

Read **`docs/AGENTS.md` first.** It is the working agreement: use the **superpowers** skills and **graphify** as mandated, claim tasks in **`docs/TASKS.md`**, and respect milestone **gates**.

- Task board / status: `docs/TASKS.md`
- Roadmap & gates: `docs/milestones/`
- Decisions: `docs/adr/`
- System specs: `docs/specs/`
- Full plan of record: `~/.claude/plans/sorted-plotting-pebble.md`
