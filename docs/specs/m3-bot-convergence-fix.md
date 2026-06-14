# M3 fix spec — decisive bot Conquest match (objective convergence)

Status: approved
Date: 2026-06-14
Relates to: [`m3-conquest-squads.md`](m3-conquest-squads.md), plan [`../plans/2026-06-14-m3-conquest-squads.md`](../plans/2026-06-14-m3-conquest-squads.md)

## Problem

The M3 gate (128-bot Conquest start→win) does not reach a winner. Isolated with a
full-speed, under-budget 48-bot run (tick mean ~18 ms, no thermal throttle): after 300 s,
`kills=0 shots=0` for the entire run, `pts=0...1` stuck, tickets barely moved (60→54/52).

Root cause: `bots/bot_driver.gd::_objective_pos` selects each bot's **nearest non-owned**
capture point. On the symmetric `proving_grounds` map the nearest non-owned point is the
team's own backfield corner (team 0 → A at (−600,0,−400); team 1 → E at (+600,0,+400)).
The two teams therefore **diverge** to opposite corners, never come within interest/engage
range, and never fight. With symmetric 1–1 ownership the flag deficit is 0, so ticket
bleed ~stops, and with no combat there are no death-tickets — the match has no path to a
decisive win. The combat/acquire logic itself is unchanged from M2 and is intact; the only
defect is movement target selection.

## Fix

**Bias the bot objective toward the map center so both teams contest the same points.**

### Component 1 — `bots/bot_driver.gd`
Add a pure, static, unit-testable selector:

```
static func choose_objective_index(points: Array, owners: Array, my_team: int,
        from: Vector3, center: Vector3) -> int
```
- Among points **not owned by `my_team`** (owner read from `owners[i]`, defaulting to
  neutral when `owners` is shorter than `points`), choose the one **nearest `center`**;
  tie-break by distance from `from`.
- If the team owns every point, fall back to **defend the nearest point to `from`**.
- Return -1 only when `points` is empty.

`_objective_pos(me)` builds an `owners` array from `_match_points` (owner per index) and
calls `choose_objective_index(_map.points-as-positions, owners, me.team, me.pos, CENTER)`
where `CENTER = Vector3.ZERO` (map points are symmetric about the origin). It returns the
chosen point's position, or `me.pos` when there is no map/points.

Because the central point (C at the origin) is the top priority for **both** teams until
owned, then the next-most-central (B/D), then the corners (A/E), both teams funnel into the
same points. They meet, the existing engage logic fires, deaths drain tickets, and the team
pushed off the central points falls into flag deficit → bleed. Convergence + captures +
combat all follow from this one selection change.

### Component 2 — `tests/bot_objective_test.gd`
Unit-test `choose_objective_index` directly (via `preload("res://bots/bot_driver.gd")`,
no Node needed):
- prefers the central non-owned point over a closer-to-bot corner;
- skips points the team already owns;
- defends the nearest point when the team owns all;
- tie-break by distance from `from`;
- empty points → -1.

### Component 3 — gate tuning (gate file only)
Keep `ci/m3_conquest_test.sh` at **128 bots**. With real combat now draining tickets, only
adjust the gate's `TICKETS` if match timing needs it. Do **not** change `shared/sim/
conquest.gd` constants (their unit tests pin capture timing); tune the gate ticket pool
instead if required, recording the value with the evidence.

## Validation

1. Prove the loop is decisive at a box-sustainable bot count (~48–64, under the 33.3 ms
   tick budget): expect `[match] OVER` with a valid winner, `kills>0`, `cap_events≥1`,
   ended via tickets (`elapsed < TIME_LIMIT`).
2. Run the full 128-bot gate unchanged. Gameplay is expected to be correct; the **tick
   budget** is expected to breach on this thermally-throttling laptop (the M2 gate also
   fails the budget on this host today — a same-day environmental swing from its recorded
   30 ms pass). That single criterion is recorded as **hardware-blocked**, to be validated
   on the separate-host bot fleet (per ADR-0001 / M8), not by weakening the assertion.

## Non-goals

Map geometry changes; enemy-seek/hunt AI; any change to the server, combat, snapshot, or
conquest rule code. This fix is confined to bot target selection plus its unit test (and an
optional gate ticket-pool value).
