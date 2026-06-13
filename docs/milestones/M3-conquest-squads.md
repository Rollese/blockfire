# M3 — Conquest + Deploy/Respawn + Squads

**Status:** todo · **Blocked by:** M2 gate

**Objective:** A complete, winnable match loop.

## Scope
- **Conquest** mode: capture points, ticket bleed, team scores, win condition.
- Data-driven map: flag/capture-point layout, team spawns (`maps/`).
- Deploy screen, respawn timer, spawn on points/squad.
- **Squad system**: create/join squad, squad list UI, squad leader, spawn on squadmate.
- Bot AI: path to nearest objective, engage visible enemies, respawn.

## Gate
A **full bot-only Conquest match runs start → win at 128 players**: bots path to nearest objective, fight, capture, respawn; a team reaches the win condition. Match observable by a human spectator client.

## Specs required
- `docs/specs/conquest-mode.md`, `docs/specs/squads.md`, `docs/specs/spawning.md`, `docs/specs/bot-ai.md`
