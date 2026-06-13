# M2 — Core FPS Loop

**Status:** todo · **Blocked by:** M1 gate

**Objective:** A recognizable shooter on top of the netcode core.

## Scope
- Movement: walk/sprint/crouch/prone, lean, jump, stamina — server-authoritative with client prediction.
- Gunplay: hit-scan + projectile weapons, recoil patterns, spread, reload, bullet drop (projectile guns), **lag-compensated hit-reg** (consumes M1 rewind).
- Health / damage / death.
- Basic class kits (Assault/Medic/Engineer/Support/Recon-style) with loadouts — data-driven.
- Blocky placeholder character + weapon art (real art deferred to M7).

## Gate
Bots can move and shoot each other, kills register correctly, and **128 bots stay stable** at 30 Hz.

## Spec (approved-pending-review)
- [`docs/specs/m2-core-fps-loop.md`](../specs/m2-core-fps-loop.md) — one consolidated doc: full movement, hit-scan gunplay, lag-compensated hit-reg (head+body hitboxes), health/death/respawn, teams (FF off), minimal classes, combat bot AI.

## Decisions (ratified)
- Lag comp: client fire-tick rewind, clamped (`MAX_REWIND`≈12 ticks) + server-validated.
- Hitboxes: two-part head sphere + body capsule, headshot multiplier.
- Weapons: hit-scan only (projectiles deferred); deterministic server-authoritative spread/recoil.
- Movement: full set (walk/sprint/crouch/prone/lean/jump/stamina).
- Teams ON (2 teams, balanced, team-separated spawns); friendly fire OFF.
