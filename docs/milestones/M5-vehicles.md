# M5 — Vehicles (Land + Air)

**Status:** **P1 (Land Vehicles + Substrate) CLOSED ✅ 2026-06-16** · P2 (Air) next · *(M4.5 precedes M5 so RPG and Engineer repair kit exist before vehicles ship)*

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

## Phase 1 (Land Vehicles + Substrate) — CLOSED ✅ (2026-06-16)

Spec: [`docs/specs/vehicles.md`](../specs/vehicles.md). Plan: [`docs/plans/m5-p1-vehicles.md`](../plans/m5-p1-vehicles.md) — 18 TDD tasks (substrate → land vehicle → gate). Built on the `m5-p1-vehicles` branch via `subagent-driven-development` (heavy server-integration tasks T10/T11/T12/T16 got read-only spec reviews; branch HEAD verified after each reviewer per [[subagent git safety]]).

**What shipped:** one armored **transport** (driver / 3 passengers / gunner) on a full vehicle substrate — `Vehicle`/`VehicleState`/`VehicleCatalog` in `shared/sim/` (deterministic custom-kinematic physics, M7-prediction-ready); multiplexed into the existing `SNAPSHOT` stream (disjoint ID range `0x40000000+`, per-client radius relevance + baseline/delta history); server enter/exit + seat slaving + gunner-turret; vehicle HP via the single `_blast_at` path (RPG/C4/frag), destruction kills occupants (incl. downed) + respawn; Engineer repair kit (overheat→cooldown, no pool); mounted gun (gunner hit-scan, lag-comp + Hitbox); anti-cheat L2 `InputValidate` (+ infantry view-rate telemetry); minimal bot crew. **309 unit tests green.**

**Gate (PASS) — layered evidence:**
- **Mechanics proven deterministically** in [`tests/vehicle_gate_test.gd`](../../tests/vehicle_gate_test.gd): RPG → vehicle HP → destruction (occupants ejected, respawn scheduled), and engineer repair → HP restored (heat-gated, caps at max). This is the authoritative proof of the combat chain.
- **128-bot fleet (scale/perf/stability)** PASS on `game2` (server pinned to P-cores 0–3): `winner=0 elapsed=272s cap_events=4 peak tick=23.67ms (<33.3) agg=17.8 Mbit/s enters=6 transport_m=930.8m`; emergent `veh_dead=1 rkt_veh=1` reported. Evidence `docker/srvlog-20260616-210141.log`. ≤48-bot CI smoke (`ci/m5_p1_test.sh`) also green.

**Balance (BattleBit-aligned, see AGENTS.md §9):** transport `max_hp=600`, RPG anti-vehicle damage `800` (a solid AT rocket one-shots a soft transport), repair `6 HP/tick`, RPG reserve `3` rockets at `150 m/s` direct-fire. Vehicle stats live in `data/vehicles.json`; repair in `data/gadgets.json`.

**Process note (AGENTS.md §10):** the fleet gate's vehicle-COMBAT counters (`veh_dead`/`rkt_veh`/`repairs`) are **reported, not gated** — they depend on emergent bot AI staging a fight, which is unreliable to tune blind. The chain is proven deterministically instead; the fleet hard-gates only perf/scale/winner/transport/boarding. **Bot vehicle tactical quality (convergence, AT aim, crew tactics) is deferred to the M7 visual-client pass**, where matches can be watched and tuned against BattleBit feel rather than blind off telemetry.

**Deferred to later M5 phases / M7:** P2 **Air** vehicles (helicopter/jet — physics + air-specific replication); vehicle client visuals + occupant body rendering + prediction; richer bot vehicle combat AI.
