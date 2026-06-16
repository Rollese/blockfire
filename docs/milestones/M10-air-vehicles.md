# M10 — Air Vehicles (final content pass)

**Status:** deferred (last) · **Blocked by:** M7 graphical client · *(scheduled last, after a working/playable game)*

**Objective:** Networked air vehicles (helicopter + jet) on the M5 vehicle substrate. **No boats** (per project scope).

## Why this is scheduled LAST (deferred from M5)

Air vehicles were originally M5-P2. They are deliberately deferred to the **final content pass**, after the rendered client (M7) and a working/playable game exist. Rationale (owner-directed, 2026-06-16):

- **Heli/jet balance and flight feel cannot be tuned blind off telemetry.** M5-P1 demonstrated how expensive blind, numbers-only tuning of even *land* vehicle behaviour is (see `docs/milestones/M5-vehicles.md` and AGENTS.md §10). Aircraft — with 6-DOF flight, lift/thrust/auto-hover, and air-to-ground/air-to-air balance — are far worse to tune without watching them fly.
- The right time is **once the graphical client (M7) exists**, so flight handling and balance can be iterated visually against BattleBit feel (AGENTS.md §9, "BattleBit Plus").

## Scope (when undeferred)

- Air vehicle entities on the existing `shared/sim/` vehicle substrate (`Vehicle`/`VehicleState`/`VehicleCatalog`, SNAPSHOT multiplex, seats/enter-exit, HP/destruction, repair) built in M5-P1.
- **Air physics** — custom-kinematic 6-DOF (pitch/roll/yaw + collective/thrust), server-authoritative, prediction-ready; auto-hover/assist for the helicopter.
- Air-specific replication tuning (higher speeds / larger interest radius / altitude) within the tick + bandwidth budget.
- Anti-air interplay (RPG/AA vs aircraft) balanced against the M5 land/AT model.
- Bot air crew behaviour is **minimal**; full air combat AI is later (M7.5 tactical AI + visual tuning).

## Gate

Air vehicles usable under load on the rendered client; flight feel + balance validated by **human playtest** (not blind telemetry); tick + bandwidth budget held at 128. Combat mechanics (AA→destruction, repair) proven deterministically as in M5-P1.

## Specs required

- `docs/specs/vehicles.md` (extend with the air section — P2 air was sketched there during M5-P1 brainstorming).
