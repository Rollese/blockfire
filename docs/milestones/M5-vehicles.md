# M5 — Vehicles (Land + Air)

**Status:** todo · **Blocked by:** M4.5 gate · *(M4.5 precedes M5 so RPG and Engineer repair kit exist before vehicles ship)*

**Objective:** Networked land and air vehicles. **No boats** (per project scope).

## Scope
- Vehicle entities with networked seats and roles (driver / passenger / gunner).
- Vehicle physics (land + air) — server-authoritative with prediction where feasible.
- Enter / exit flow; vehicle health/destruction.
- Minimal bot vehicle behavior (occupy / transport); full vehicle combat AI is later.
- **Engineer vehicle repair kit** (defined in M4.5, wired here): Engineer hold-action near a vehicle restores vehicle HP at `REPAIR_RATE` per tick; server-authoritative. **Unlimited but rate-limited (like medic active heal / support active ammo), with a BattleBit-style overheat → 5 s cooldown after continuous use — no per-spawn charge pool.** See [vehicles spec](../specs/vehicles.md) §6.
- **RPG anti-vehicle damage** (RPG weapon defined in M4.5): wire RPG detonation blast into the vehicle HP system. RPG already damages structures + pawns from M4.5; vehicle HP target is added here.
- **Anti-cheat Layer 2 — server-side input validation** (earliest landing point): bound-check inputs at the sim boundary (move/teleport, view rate, fire cadence vs ammo) **incl. new vehicle inputs** (throttle/steer/seat actions). Rules in `shared/`. See [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md) / [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md).

## Gate
Vehicles usable under load; bots can at least occupy and transport via vehicles; tick + bandwidth budget held.

## Specs required
- `docs/specs/vehicles.md`
