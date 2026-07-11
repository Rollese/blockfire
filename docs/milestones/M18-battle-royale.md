# M18 — Battle Royale game mode (squad, last-squad-standing)

**Status:** planned (plan of record) · **Sequence:** **deferred until the core mechanics + rendered client are solid** (post-M7/M7.5/M8), as the first new content mode after Conquest/Assault · **Decision:** [ADR-0009](../adr/0009-game-mode-strategy.md) · **Spec:** [`battle-royale-mode`](../specs/battle-royale-mode.md)

**Objective:** A third match mode beside Conquest (M3) and Assault (M13). ~128 players in **squads of 4** parachute onto a large map, **scavenge** all gear from the ground, and fight inward as a **shrinking zone** forces contact until **one squad remains**. PUBG/BattleBit-flavored — **no Fortnite instant-build**; the destruction sim and shovel construction stay intact. Built as a **rules variant over the shared deterministic sim** — not a new sim. **Session-only: no persistence / accounts / backend — zero M9 dependency.**

## Why deferred (not build-now)

Per [ADR-0009](../adr/0009-game-mode-strategy.md): new modes are content, not core-loop dependencies, and BR is the **first mode to add after the core is solid** — because it is the cheapest, highest-synergy variant (reuses the netcode, destruction, DBNO/revive, armor, ammo, and shovel construction already built and gated). It is most tunable for feel once the rendered client (M7), tactical bots (M7.5), and ops hardening (M8) exist. This milestone is the **plan of record** now; no TDD implementation plan is written until it is undeferred. This ordering also reflects the owner's foundation-first discipline — finish and playtest the core before adding modes.

## Scope (when undeferred)

- **Mode setting** (`mode ∈ {CONQUEST, ASSAULT, BATTLE_ROYALE}`); default Conquest unchanged.
- **BR match-state** (`shared/sim/br.gd`): DROP → LIVE → OVER; squad-alive tracking; last-squad-standing win + fail-safe.
- **Shrinking zone** (`shared/sim/zone.gd`): ~6–8 phases, randomized next-center, escalating out-of-zone DoT; pure damage field, no destruction interaction; `ZONE_STATE` wire.
- **Loot** (`shared/sim/loot.gd` + ground-item entities, `data/loot.json`): weighted rarity tables on **attachments/armor/ammo/gadgets** (not stat-inflated weapons — AGENTS.md §9); crates + timed **supply drops**; pickup/swap reusing armor.gd / M17 reserve-ammo / M4.5 attachments.
- **Deploy**: scripted non-flyable transport + **kinematic parachute-glide** pawn state (no M10 dependency).
- **Downed/redeploy**: reuse M4.5-P1 DBNO/revive; add **one-time beacon buy-back** (scattered redeploy beacons) — not a gulag arena.
- **Building**: existing shovel construction with a **BR-mode speed multiplier** (fast cover); no new build system.
- **Protocol**: mode byte extension + `ZONE_STATE`, ground-item spawn/pickup, `DEPLOY_STATE`, `REDEPLOY_*` messages (bump `Protocol.VERSION`).
- **Bot AI**: M7.5 engine extended with drop/loot/zone-rotation/endgame behaviours; the fleet gate driver exercises a full BR match.
- **Content dependency**: a **large BR map with distributed loot POIs** (drop path, loot points, supply-drop locations, zone schedule) — the main new-content item; can run as a parallel track.

## Gate

A **128-bot BR match** validated bot-fleet-style, mechanics proven deterministically (AGENTS.md §10):

- Full match **drop → loot → zone shrinks through all phases → one squad remains** (`winner=<squad>`), ended by elimination (not only the time fail-safe).
- **Loot** picked up + upgraded (telemetry); at least one **supply drop** contested.
- **Zone** out-of-zone DoT observed; bots rotate with the circle.
- **DBNO + revive** and **one beacon redeploy** observed in-match.
- **Tick + bandwidth budget held** (mean tick < 33.3 ms at 128 — expected comfortable margin, since entity count drops across a BR match; see spec §G).
- Win condition, zone stepping, loot rolls, and redeploy-once semantics proven in unit/integration tests independent of emergent bot AI.

## Depends on

- **M3** squads + **M4/M11** destruction + **M4.5** DBNO/revive & attachments + **M12** shovel construction + **M16** bleed/bandage + **M17** reserve-ammo + the interest/snapshot/degrade netcode — all reused, not rebuilt.
- **Core solid** (M7 client + M7.5 bots incl. P4 + M8 ops) before implementation begins.
- A **large BR map** (new content track).

## Specs

- [`docs/specs/battle-royale-mode.md`](../specs/battle-royale-mode.md) — brainstormed; design approved 2026-07-11.
- [ADR-0009](../adr/0009-game-mode-strategy.md) — game-mode strategy (why BR is the first new mode, and a rules-variant not a new game).
