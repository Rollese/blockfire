# Bot RPG-at-structure restraint — map-chewing balance pass (2026-07-09)

Autonomous non-graphical session, continuing the bot-AI lane after the building/wall avoidance change
(`5891a52`). Target: the documented `bot-ai.md §8` balance gap — Engineer bots demolish the map.

## Problem
Vehicles were removed from every shipping map (`vehicle_spawns: []`, owner-directed 2026-07-05). So the
anti-vehicle `maybe_rpg` never finds a target and **always** falls through to `maybe_rpg_building`,
which lobbed a rocket at the *nearest wall* every `RPG_FIRE_COOLDOWN` (~4 s) for the whole match. Owner
playtest: ~**815 rockets / 28 min** across ~24 bots → ~**27 %** of `conquest_town` wrecked, 12 collapses.
A player joining a mature match dropped into a ruin — un-BattleBit-like.

## Fix — `bots/exercisers.gd` + `bots/bot_driver.gd` (bot-only / AI layer, no wire/sim change)
Two levers from the spec's suggested list ("cap structure cadence" + "gate behind a real target"):
- **Cadence cap (the rate lever):** `RPG_STRUCTURE_COOLDOWN = 600` ticks (~20 s) — 5× the anti-vehicle
  `RPG_FIRE_COOLDOWN` (120). Tracked separately (`rpg_struct_last_tick`) so the anti-vehicle path is
  untouched.
- **Enemy-cover target preference:** `BotExercisers.rpg_structure_target` (pure, unit-tested) prefers
  the nearest structural piece a **visible enemy is using as cover** (enemy within 6 m of it), and only
  falls back to the nearest piece overall when none qualifies — so the rockets that fly concentrate on
  contested cover, and the destruction mechanic still exercises on sparse maps.

## Verification
- `tests/bot_rpg_restraint_test.gd` (5, pure): enemy-cover preference beats a closer empty wall,
  nearest fallback, no-enemy fallback, out-of-range, non-building filtered. Suite **1409 / 0**.
- **M11 GATE-A PASS on `conquest_town`** (the default gameplay map, buildings at the capture points):
  `winner=1 elapsed=103s destroyed=2 rstruct=8 rockets=7 peak tick=23.70ms` — **rockets ≈ 114/28 min
  vs. the old 815 → ~7× fewer**, destruction still fires. Evidence
  `docs/gate-evidence/20260709-bot-rpg-restraint.txt`.
- **Control** (pre-change RPG, HEAD `5891a52`) on `conquest_proving_grounds`: `destroyed=1 rockets=1` in
  242 s — the sparse map's 4 far bunkers are reach-limited, so its destruction signal sits at the noise
  floor **even without the change**. That's why the two proving_grounds runs of the new code hit
  `destroyed=0`, and why the realistic destruction gate for a bot-RPG-*rate* change is `conquest_town`.

## Notes for the next agent
- **Did NOT edit `docker/run-m11-gate.sh`** (its default map is `conquest_proving_grounds`) — that
  destruction-gate infra is the concurrent buildings agent's lane. Run the M11 gate with
  `MAP=conquest_town` to validate any bot-combat/RPG change; recorded this in `bot-ai.md §8`.
- If bots still chew too much / too little, the knobs are `RPG_STRUCTURE_COOLDOWN` (rate) and
  `RPG_STRUCTURE_ENEMY_RADIUS` (how tightly fire tracks enemy cover), both in `bot_driver.gd`.
- Deeper BattleBit-authentic follow-up (not done): rockets are reserve-limited in BattleBit; bots
  refill at ammo bags, which is how 815 was reachable. A reserve/resupply model would cap it more
  naturally than a cadence, but is a bigger change.
