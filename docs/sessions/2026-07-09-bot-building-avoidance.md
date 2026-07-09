# Bot building/wall avoidance — reactive obstacle sidestep (2026-07-09)

Autonomous non-graphical polish session. Target: the long-deferred **bot pathfinding** gap (memory
"F2 bot pathfinding", "map design+bot pathfinding" deferred repeatedly). No screenshots needed —
proven deterministically + fleet gate.

## Problem
Every bot movement is straight-line steering (`AiDriver._flat_dir` → march/engage/flee toward a
point). The only avoidance was **terrain-slope** sidestep (M15, `bot_driver.slope_sidestep`), which
samples ground *slope* left/right of the heading. On level ground next to a **building**, both sides
read as equally walkable, so `slope_sidestep`'s tie-break blindly always picks **left** — a bot
pressed flat against a wall shuffles left into the corner and stalls there for the rest of its life.
Bots never routed around building footprints.

## Fix — `bots/bot_driver.gd` (bot-only, presentation/AI layer)
The bot already receives `bot["structs"]` (its interest-culled synced structure cells) but only used
them for cover-scoring. Now, when a march **stalls** (the existing `is_slope_stuck` commanded-vs-actual
check) and the ground dead ahead is **walkable** (not a slope block), the bot escapes toward the
**clearer side** of the nearby building cells:

- `obstacle_sidestep(pos, heading, obstacles)` — pure: probe clearance one cell down each lateral
  (left/right off the heading, each folded with a small retreat so a flush press still yields lateral
  travel), steer toward the side whose nearest obstacle is farther. Reactive wall-follow that rounds
  the footprint over successive 18-tick override windows.
- `nearby_obstacle_cells(structs, pos)` — pure: world-space centres of synced cells within 6 m
  horizontally and one floor (3 m) vertically, so upper storeys of a tall building don't count as
  ground obstacles.
- `_pick_sidestep(bot, me, heading)` — routes a stall to `slope_sidestep` when the ground ahead is
  genuinely too steep (`> MAX_WALKABLE_SLOPE_DEG`), else to `obstacle_sidestep`.

Wiring: the stuck-avoid call-site guard changed from `_terrain != null` to just `not is_driller`
(the slope path stays terrain-gated inside `_pick_sidestep`), so building avoidance also works on a
hypothetical flat map with structures. CLIMB drillers / shovel-drillers / FOB leaders are untouched —
they self-send and `return` before the avoid block, so the deterministic gate drills are unaffected.

**NOT sim-authoritative, NOT full pathfinding** — the server still clips every bot's movement via
`Terrain.resolve_movement` exactly like a human. This only stops the AI from commanding a
permanently-blocked heading. No wire/protocol/sim change.

## Verification
- `tests/bot_obstacle_avoid_test.gd` (6 tests): sidestep away from a left wall / right wall, strong
  lateral (not pure retreat) escape, zero-heading no-op, cell range+floor filtering, stuck reuse.
- Full suite **1404 run / 0 failed**.
- **Fleet gate PASS** (`MAP=conquest_town`, 128 bots): winner in 67 s, peak tick **23.44 ms**
  (budget 33.3), 18 kills, cap_events=1 (non-inert). Evidence:
  `docs/gate-evidence/20260709-175409-obstacle-avoid.txt`. Live bot movement not regressed.

## Notes for the next agent
- This is *reactive* (bump-then-slide), not planned A*. It clears the "stuck in a wall forever"
  failure and rounds building footprints, which is the owner-visible problem. If a future map has
  deep concave pockets, a proper nav grid would be the next step — but the reactive layer keeps the
  fleet moving and is cheap (runs only on a detected stall).
- Constants to tune if bots hug walls too tightly / too loosely: `OBSTACLE_SCAN_RADIUS` (6 m),
  `OBSTACLE_RETREAT_BLEND` (0.5), `SLOPE_OVERRIDE_TICKS` (18, shared with slope-avoid).
