# Spec: Battle Royale game mode (squad, last-squad-standing)

**Status:** plan of record (design approved 2026-07-11) · **Milestone:** [M18](../milestones/M18-battle-royale.md) · **Decision:** [ADR-0009](../adr/0009-game-mode-strategy.md)

A third match mode beside Conquest (M3) and Assault (M13): ~128 players in **squads of 4** drop onto a large map, **scavenge** all gear from the ground, and fight inward as a **shrinking zone** forces contact until **one squad remains**. A PUBG/BattleBit-flavored BR — **no Fortnite instant-build**; the existing destruction sim and shovel construction stay intact. Built as a **rules variant over the shared deterministic sim** (`shared/sim/`, server-authoritative) — not a new sim, in the same spirit as Assault. **Session-only: no meta-progression, no persistence, no online backend — zero [M9](../milestones/M9-online-services.md) dependency** (the hard line separating BR from the future extraction mode, [ADR-0009](../adr/0009-game-mode-strategy.md) §3). **Implementation is deferred** until the core mechanics + rendered client are solid (post-M7/M7.5/M8) — this spec is the plan of record, not a build-now task.

## Design decisions (ratified — see ADR-0009 §2, owner 2026-07-11)

| Decision | Choice | Rationale |
|---|---|---|
| Flavor | **PUBG/BattleBit BR** (no instant build) | Coherent with Blockfire's identity; keeps the destruction sim + shovel construction; lowest cost. |
| Persistence | **None — session-only** | Keeps BR a pure rules-variant with no M9 backend; the RPG/extraction mode is the one that needs persistence. |
| Squad structure | **Squads of 4, ~128 players** (~32 squads) | Reuses M3 squads as-is; matches the netcode ceiling gated at 128 bots; fits the squad-centric, tactical-team identity. Solo/duo queues **deferred** (squad teamwork is the point). |
| Start kit | **Weak pistol + shovel + fists**; everything else looted | The authentic scavenge loop; a floor weapon so nobody is defenceless on drop. |
| Loot rarity | Tiers on **attachments, armor, ammo, gadget availability** — **not** stat-inflated base weapons | Preserves the flat, skill-based balance rule (AGENTS.md §9). A looted gun is the same gun; rarity means better optics/armor/ammo. This is what makes BR loot legitimate where RPG-stat loot would need its own ADR. |
| Deploy | **Scripted non-flyable transport + kinematic parachute-glide** | Delivers the iconic drop + landing-choice **without** an M10 air vehicle; a new deploy/movement state in the zero-physics sim. |
| Building | Existing shovel construction with a **BR-mode speed multiplier** (cover completes in a few seconds) | Fast cover for BR pacing without a new build system; destruction model unchanged. A per-mode tuning constant. |
| Downed | **DBNO + revive** (reuses M4.5-P1) | The downed/revive substrate already exists; BR reuses it. |
| Redeploy | **One-time beacon buy-back** (squadmate reaches a redeploy beacon) | A comeback mechanic that reuses the "interact-with-a-structure-to-deploy" pattern (FOB-like), avoiding an instanced 1v1 gulag arena + dead-player matchmaking (real extra netcode). |
| Zone | Concentric shrinking safe-zone, ~6–8 phases, randomized next-center, escalating out-of-zone DoT | Genre-standard; a pure damage field in the sim, **no** destruction interaction. |
| Win | **Last squad standing**; final tiny zone + time fail-safe force resolution | Standard BR termination; the fail-safe prevents stalemate. |
| Supply drops | **Yes** — timed high-tier crates at telegraphed locations mid-match | Contested loot events that pull squads together; reuses the crate/loot-entity system. |

## A. Mode selection & map data

- `mode ∈ {CONQUEST, ASSAULT, BATTLE_ROYALE}` at match start (extends the M13 mode byte); default Conquest unchanged.
- BR map data (`maps/*.json`) gains a BR block: **drop-transport path** (start/end + altitude), **loot-spawn points** with weighted table refs, **supply-drop candidate locations**, and **zone parameters** (initial center/radius, per-phase shrink schedule). No team spawns/uncaps/CPs are used in BR.
- BR needs a **large map with distributed loot POIs** — see §I (the main new-content dependency).

## B. BR match-state (`shared/sim/br.gd`, sibling of `conquest.gd`)

A new mode-state module stepped by the server each tick, in the same slot Conquest/Assault occupy:

- **Phases:** `DROP` (transport in flight, players gliding) → `LIVE` (zone active, shrinking through its schedule) → `OVER` (one squad remains or fail-safe).
- **Squad-alive tracking:** a squad is alive while ≥1 member is deployed, DBNO, or beacon-redeployable. Win check each step: exactly one squad alive → that squad wins; zero (mutual final-circle wipe) → resolved by last-eliminated / most-damage fail-safe.
- **Elimination:** feeds off the existing DBNO/death path — full elimination (bled out, no revive, no redeploy left) removes the player from the alive set; entity count **drops** across the match (see §G, why the netcode is easier than Conquest).

## C. Zone (`shared/sim/zone.gd`)

- Pure sim module: current center, current radius, next center, next radius, phase index, per-phase timings, DoT rate. Deterministic (seeded per match) so the client mirrors it exactly and bots read it.
- Each phase: a **hold** window (zone stable, next circle telegraphed) then a **shrink** window (radius interpolates to the next circle). Out-of-zone players take **DoT that escalates by phase**. The zone does **not** damage or interact with structures.
- Wire: a compact `ZONE_STATE` message (center, radius, next-center, next-radius, phase, shrink-eta) sent on phase transitions + paced keyframes; the client interpolates the ring.

## D. Loot (`shared/sim/loot.gd` + ground-item entities)

- **Loot tables** (data-driven, `data/loot.json`): weighted item entries by rarity tier; tables referenced from map loot-spawn points and from crate/supply-drop types.
- **Ground items** are lightweight replicated entities (spawn → interest-scoped replication like structure events → pickup removes them). An item carries: kind (weapon/attachment/armor/ammo/gadget), rarity tier, and payload (which weapon, which attachment, armor tier, ammo count).
- **Pickup/swap:** interact to pick up; picking a weapon you can't carry swaps it to the ground. Armor tiers reuse `armor.gd`; looted ammo feeds the M17 `reserve_ammo` pool; attachments reuse the M4.5 attachment system.
- **Crates** (static, at map loot points) and **supply drops** (timed, telegraphed, higher-tier) use the same ground-item spawn path with richer tables.

## E. Deploy / parachute-glide (new pawn state)

- At match start the transport traverses the map on the data-defined path; players are attached until they **jump**.
- **Glide** is a new kinematic movement state (fits the zero-physics sim, [ADR-0005](../adr/0005-client-renderer.md)): free-fall with player-steered horizontal control and a parachute deploy that caps descent; landing transitions to the normal grounded pawn state. Fully server-authoritative + predicted like all movement.
- Wire: deploy/glide reuses the movement input channel; a small `DEPLOY_STATE` field marks in-transport / gliding / landed for the client viewmodel + others' visuals.

## F. Downed / redeploy / beacon

- **DBNO + revive:** reuse M4.5-P1 unchanged (crawl, bleed-out timer, squadmate revive; interacts with the M16 standing-bleed/bandage loop as it does elsewhere).
- **Beacon buy-back (once per eliminated player):** on full elimination the player becomes **redeployable**. A living squadmate interacts with a **redeploy beacon** (map-scattered structures) to bring them back — gliding in from a fresh transport pass. Each eliminated player is redeemable **once**; after a second elimination they are out for good. A `REDEPLOY_*` wire message covers the beacon interaction + the pending/consumed redeploy state.
- Beacons are finite and located, so redeploy is a **positional risk/reward**, not a free respawn.

## G. Budgets & netcode note

- **Tick + bandwidth budget unchanged:** mean tick < 33.3 ms at 128, held on the fleet like every other mode.
- **BR is *milder* than Conquest on the tick**, not harsher: early game players are spread across a huge map (interest management thrives — fewer relevant entities per client), and **entity count monotonically drops** as eliminations occur, so the crammed final circle holds only a few squads. The O(N²)-ish snapshot worst case (all clients see everyone) can only occur late, when N is small. Ground-loot and zone add per-tick work, but loot is interest-scoped and event-driven (like structure deltas) and the zone is O(1). Re-profile `[perf]` when built, but the expectation is comfortable margin.

## H. Bot AI (`bots/ai/` + `bots/bot_driver.gd`)

Extends the M7.5 engine with BR behaviours (fair-play, same perception the humans have):
- **Drop:** choose a landing POI (spread across squads); glide to it.
- **Loot:** seek/pick ground items to fill empty slots and upgrade rarity; prioritise weapon → armor → ammo.
- **Zone rotation:** read `zone.gd`; path to stay inside the safe circle ahead of the shrink; fight or avoid based on the existing utility scoring.
- **Endgame:** tighten with the circle; contest supply drops. Squad-coordinated per M7.5-P4 when available.
- The bot fleet is what gate-validates BR (below), same as all prior modes.

## I. Dependencies

- **Large BR map with distributed loot POIs** — the single biggest new-content item. Either scale up an existing map or author a new one; it must define the drop path, loot points, supply-drop locations, and zone schedule (§A). This is a content track that can run in parallel once BR is undeferred.
- **Core solid** (M7 client + M7.5 bots incl. P4 + M8 ops) before implementation begins, per ADR-0009 §4.
- Reuses (no new build): M3 squads, M4/M11 destruction, M4.5 DBNO/revive + attachments, M12 shovel construction (tuned), M16 bleed/bandage, M17 reserve-ammo, `armor.gd`, the interest grid + snapshot + degrade netcode.

## J. Gate (when undeferred)

A **128-bot BR match** validated bot-fleet-style (AGENTS.md §10), with mechanics proven deterministically:
- A full match runs **drop → loot → zone-shrinks-through-all-phases → one squad remains** (`winner=<squad>`), ended by elimination (not only the time fail-safe).
- **Loot** observed: bots pick up ground items and upgrade (telemetry counters). **Supply drop** contested at least once.
- **Zone** exercised: out-of-zone DoT observed; bots rotate with the circle.
- **DBNO + revive** and **one beacon redeploy** each observed in-match.
- **Tick + bandwidth budget held** (mean tick < 33.3 ms at 128; expected comfortable margin per §G).
- Win condition, zone stepping, loot-table rolls, and redeploy-once semantics proven in unit/integration tests independent of emergent bot AI.

## K. Out of scope (explicit)

- **Any persistence / meta-progression / accounts / anti-cheat backend** — session-only; that is the extraction mode's territory (M9++), not BR.
- **Solo / duo queues** — squad-only at launch (deferred; the mode is built around squad teamwork).
- **Fortnite instant-build / harvesting / material economy** — explicitly rejected (§ Design decisions).
- **Vehicles** — folded into the deferred Vehicles milestone (TASKS.md 2026-07-05); BR ships infantry-only unless/until that milestone reopens.
- **Gulag-style 1v1 redeploy arena** — beacon buy-back chosen instead (avoids an instanced sub-arena + dead-player matchmaking).
- **RPG stats / stat-rolled weapons** — would need its own identity ADR (ADR-0009 §4); BR rarity is attachments/armor/ammo only.
