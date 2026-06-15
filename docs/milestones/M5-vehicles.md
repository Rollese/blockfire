# M5 — Vehicles (Land + Air)

**Status:** todo · **Blocked by:** M3 gate · *(M4–M6 may be reordered)*

**Objective:** Networked land and air vehicles. **No boats** (per project scope).

## Scope
- Vehicle entities with networked seats and roles (driver / passenger / gunner).
- Vehicle physics (land + air) — server-authoritative with prediction where feasible.
- Enter / exit flow; vehicle health/destruction.
- Minimal bot vehicle behavior (occupy / transport); full vehicle combat AI is later.
- **Anti-cheat Layer 2 — server-side input validation** (earliest landing point): bound-check inputs at the sim boundary (move/teleport, view rate, fire cadence vs ammo) **incl. new vehicle inputs** (throttle/steer/seat actions). Rules in `shared/`. See [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md) / [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md).

## Gate
Vehicles usable under load; bots can at least occupy and transport via vehicles; tick + bandwidth budget held.

## Specs required
- `docs/specs/vehicles.md`
