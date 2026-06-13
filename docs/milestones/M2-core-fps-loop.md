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

## Specs required
- `docs/specs/movement.md`, `docs/specs/gunplay-hitreg.md`, `docs/specs/classes-loadouts.md`
