# Spec: M3 Conquest + Deploy/Respawn + Squads

**Status:** approved (implemented; gameplay gate passed — see milestone doc) · **Date:** 2026-06-14 · **Milestone:** [M3](../../milestones/M3-conquest-squads.md)

Builds the complete, winnable match loop on top of the M2 FPS core: a data-driven **Conquest** mode (capture points, ticket bleed, win condition), squads, server-authoritative deploy/respawn with point/squad spawns, and bots that path to objectives and capture them. Stays server-authoritative; all match rules live in `shared/` so client and server can't diverge (AGENTS.md §5, §7). The gate is **bot-only**: a full 128-player Conquest match must run start → win.

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Ticket model | **Bleed + kill cost** | Each team has a ticket pool; deaths cost 1, flag deficit bleeds. Captures *and* kills both push the match to a conclusion. |
| Capture mechanic | **Neutralize-then-take, pause on contest** | An enemy point must drain to neutral before it can be captured; both teams present → frozen. Readable, Battlefield-style. |
| Map layout | **5 capture points (A–E) + 2 home bases** | Good spatial spread for 128p (lower interest density); home bases keep a team from being fully spawn-trapped. |
| Opening ownership | **All 5 points start neutral** | Both teams rush out from home bases; no initial bleed deficit; symmetric land-grab opening. |
| Map format | **JSON in `maps/`** | Easiest to hand-author and git-diff (agents are the map authors); small testable loader; data cleanly separate from code. Editor/`.tres` workflow deferred to M7. |
| Squads | **Size 8, spawn on any alive squadmate** | 64/team → 8 squads of 8; fewer squads to track; strong squad-rally spawning. Squads never span teams. |
| Spawn sources | **Home base + owned points + alive squadmate** | Full tactical spawn set matching the 5-points-plus-base layout. |
| Team/squad balance | **Keep M2 team-balance; fill squads within team** | Minimal change to existing assignment; squads are within-team. |
| Deploy flow | **Server auto-selects spawn in M3** | Client deploy-screen UI is headless until M7; M3 ships the server selection + the replicated data a deploy screen needs. |
| Bot objective AI | **Nearest point not owned by my team; else defend nearest** | Simple, reliably produces captures → bleed → a winnable match. |

## Budgets (M3 gate pass/fail)

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), including conquest stepping + match-state broadcast. (Perf pre-filter below protects the p99 edge under objective clustering.)
- Bandwidth budgets unchanged from M1/M2 (≤ ~64 KB/s mean per client; < ~250 Mbit/s aggregate). `MATCH_STATE` adds ~20 bytes at 2 Hz — negligible.
- **Functional gate:** a 128-bot, 2-team Conquest match runs **start → win**: bots path to objectives, neutralize/capture points (point ownership demonstrably changes), fight, respawn; a team reaches the win condition and the match ends with a declared winner.

---

## Module layout (extends M2)

```
shared/sim/
  map_def.gd        NEW  MapDef: load_from_json(path) -> MapDef; points[]/bases[]; validation
  conquest.gd       NEW  ConquestState: per-point owner/attacker/cap; tickets[2]; step(); win check
shared/net/
  protocol.gd       (mod) + Msg.MATCH_STATE encode/decode
  entity_state.gd   (mod) + squad
  snapshot.gd       (mod) + F_SQUAD field bit
maps/
  conquest_proving_grounds.json   NEW  v1 map: 5 points + 2 bases
server/server_main.gd  (mod) load map; squad assignment; conquest step; spawn selection;
                              match-state broadcast; perf pre-filter in _fire_shot; match-end
bots/bot_driver.gd     (mod) load map; objective selection from match state; path to objective; capture
ci/m3_conquest_test.sh NEW  gate: 128 bots run to a win; assert winner + captures + tick budget
```

---

## A. Map data (`shared/sim/map_def.gd`, `maps/*.json`)

JSON schema (`conquest_proving_grounds.json`):

```json
{
  "name": "proving_grounds",
  "world_half": 1000.0,
  "points": [
    {"id": "A", "pos": [-600, 0, -400], "radius": 30.0, "start_owner": -1},
    {"id": "B", "pos": [-300, 0,  300], "radius": 30.0, "start_owner": -1},
    {"id": "C", "pos": [   0, 0,    0], "radius": 30.0, "start_owner": -1},
    {"id": "D", "pos": [ 300, 0, -300], "radius": 30.0, "start_owner": -1},
    {"id": "E", "pos": [ 600, 0,  400], "radius": 30.0, "start_owner": -1}
  ],
  "bases": [
    {"team": 0, "pos": [-900, 0, 0], "radius": 40.0},
    {"team": 1, "pos": [ 900, 0, 0], "radius": 40.0}
  ]
}
```

- `MapDef.load_from_json(path)` parses and **validates**: required fields present, `points` non-empty, each `pos` is a 3-number array, `radius > 0`, `start_owner ∈ {-1,0,1}` (default `-1` if omitted), exactly one base per team `{0,1}`. On any error it returns an error result (loader is tested) — the server refuses to start on an invalid map.
- Points are indexed `0..N-1` in array order; `id` is a display label only. Capture order on the wire is array order.
- Home bases are **uncapturable** spawn anchors, not part of the conquest point set.

---

## B. Conquest state machine (`shared/sim/conquest.gd`)

Per point: `owner ∈ {-1,0,1}` (−1 = neutral), `attacker ∈ {-1,0,1}` (team currently advancing, else −1), `cap ∈ [0.0,1.0]` (progress of the current phase). `tickets := [T0, T1]`. Constructed from a `MapDef` (seeds `owner` from `start_owner`).

`step(dt, world)` each server tick:

1. **Presence:** count alive players of each team whose `pos` (planar XZ) is within each point's `radius` → `(n0, n1)` per point.
2. **Resolve per point:**
   - **Contested** (`n0>0 and n1>0`): freeze — `cap` and `attacker` unchanged.
   - **One team T present** (`nT>0`, other 0):
     - If `owner == T`: defending an owned point → `cap=0`, `attacker=-1` (no-op).
     - Else (owner is −1 or the enemy): `T` advances. If `attacker != T`, reset `attacker=T, cap=0` (a new team restarts progress). `rate = CAP_RATE_BASE * (1 + CAP_BONUS_PER * (min(nT, CAP_MAX_ATTACKERS) - 1))`; `cap += rate*dt`.
       - On `cap >= 1.0`:
         - If `owner` was the **enemy** → this was the **neutralize** phase: set `owner=-1`, `cap=0` (point now neutral; the same team will capture it on subsequent ticks).
         - If `owner` was **neutral** → this was the **capture** phase: set `owner=T`, `attacker=-1`, `cap=0`.
   - **Empty** (`n0==0 and n1==0`): if a capture was in progress (`attacker != -1`), `cap = max(0, cap - CAP_DECAY_RATE*dt)`; at 0, `attacker=-1`. Owned points stay owned.
3. **Tickets / bleed:** for each team, `deficit = max(0, owned_points(other) - owned_points(self))`; `tickets[self] -= BLEED_PER_FLAG * deficit * dt` (fractional, accumulated). Death cost is applied by the server when a kill resolves (see §C).
4. **Win check:** if either team's tickets `<= 0` → clamp to 0, set `match_over=true`, `winner = the other team`. Ties (both hit 0 same tick) → higher remaining (or team 0) wins; effectively can't both cross in one tick under integer death + small bleed.

Taking a fully enemy-held point therefore costs **two phases** (neutralize, then capture); a neutral point costs **one**. More attackers (up to `CAP_MAX_ATTACKERS`) capture faster.

**Initial constants (gate-tuned in `ci/m3_conquest_test.sh`):**

| Const | Value | Meaning |
|---|---|---|
| `TICKETS_START` | 250 | per-team starting pool |
| `BLEED_PER_FLAG` | 1.0 | tickets/s lost per flag of deficit |
| `DEATH_TICKET_COST` | 1 | tickets lost by victim's team per death |
| `CAP_RATE_BASE` | 0.10 | per-second `cap` gain for a single attacker (≈10 s/phase solo) |
| `CAP_BONUS_PER` | 0.20 | extra rate fraction per additional attacker |
| `CAP_MAX_ATTACKERS` | 8 | attacker count cap for rate scaling |
| `CAP_DECAY_RATE` | 0.05 | per-second `cap` decay when point empty |
| `MATCH_TIME_LIMIT` | 1200 s | fail-safe; on expiry, more tickets wins |

These are starting points; the implementer tunes within the spec's model so the 128-bot gate match finishes via tickets in a few minutes (not via the time fail-safe).

---

## C. Tickets, death cost, win condition

- Death: when the server resolves a kill (existing `_fire_shot`), decrement `tickets[victim.team] -= DEATH_TICKET_COST` (in addition to scheduling respawn).
- Bleed: applied in `conquest.step` per §B.3.
- Win: first team to `tickets <= 0` loses; broadcast match end (see §F); server stops accepting fires/captures and logs the result. For the gate the server may exit after a short drain window.

---

## D. Squads (server-side, replicated)

- `SQUAD_SIZE = 8`. Server tracks `squad_id` per client (within team) and a per-team list of squads.
- **Assignment on join:** team chosen by the existing "smaller team" rule (`server_main._handle_hello`), then placed in the **first non-full squad on that team** (creating a new squad if all are full). Squad ids are per-team (`0..7`). Squads never span teams.
- **Leader:** first member of a squad is leader; on leader disconnect/leave, promote the next member; empty squads free their id.
- **Replication:** `squad_id` is replicated via `EntityState.squad` (delta-compressed). Leader flag is not separately replicated in M3 (derivable later / not needed for the bot gate).

---

## E. Spawning / deploy (server-authoritative)

Replaces M2's `_spawn_pos(team)` (`x<0 / x>0` halves).

`_select_spawn(client) -> Vector3`:
- **Valid sources** for the client's team `T`:
  - the team's **home base** (always valid),
  - every **capture point owned by `T`** (`owner == T`),
  - every **alive squadmate** (same `squad_id`, `alive`, not self).
- **Choice policy (M3 auto-deploy):** pick the valid source **nearest the client's current objective** (the bot's target point; for a source-less case, nearest to map center). This minimises walk time to the front. Humans will instead pick a source in M7 (the data is the same).
- **Position:** `source.pos + random offset within SPAWN_JITTER` (default 6 m), `y=0`, clamped to world bounds. Squadmate spawns jitter around the squadmate.
- **First spawn (join) / all points neutral:** only home base + squadmates are valid → effectively home base, as intended for the neutral opening.

Respawn timing is unchanged (`RESPAWN_DELAY_TICKS = 150`, 5 s). The dead pawn waits out the timer, then the server calls `_select_spawn` and revives it (full health/ammo/stamina, as M2).

The explicit **client deploy message** (client chooses a spawn source) is **deferred to M7** with the client UI. M3 replicates everything a deploy screen needs (point ownership + squad roster via snapshots, tickets via `MATCH_STATE`).

---

## F. Wire protocol changes

**`EntityState` + `squad` (u8):** add field, included in `clone()` and `Pawn.to_state()`. New snapshot field bit **`F_SQUAD`** — this is the **8th** field (`F_POS_X/Y/Z, F_YAW, F_PITCH, F_STATE, F_HEALTH, F_SQUAD`), filling the u8 `field_mask` exactly. Delta-compressed: squad changes rarely → ~zero steady-state cost. Snapshot encode/decode round-trips the new field.

**New `Msg.MATCH_STATE` (server→client):**
- Body: `point_count u8`, then per point `{owner i8, attacker i8, cap u8}` (`cap` quantized `0..1 → 0..255`), then `tickets0 u16`, `tickets1 u16`, `match_over u8`, `winner i8`, `elapsed u16` (seconds).
- **Cadence:** sent **unreliably** to all clients every `MATCH_STATE_INTERVAL = 15` ticks (2 Hz). On **match end**, sent once **reliably** on the CONTROL channel.
- Clients/bots cache the latest. ~20 bytes/message; negligible.

No INPUT changes in M3 (movement/fire input unchanged from M2).

---

## G. Bot AI (`bots/bot_driver.gd`)

Bots load the same map JSON at startup (point positions/radii) and cache the latest `MATCH_STATE` (point ownership).

Per tick, in addition to the existing combat AI (acquire/aim/fire/respawn unchanged):
1. **Objective:** the **nearest point with `owner != my_team`** (neutral or enemy — capturable). If my team owns all points, **defend** the nearest point. Cache/hysteresis so the objective doesn't thrash tick-to-tick.
2. **Path:** move toward the objective in world space (replacing M2's "advance toward enemy +x/−x"). When an enemy is acquired, the existing combat movement (advance/engage) takes priority within engage range; otherwise march to the objective.
3. **Capture:** simply being alive inside the objective's radius drives `conquest.step` server-side — no special bot action needed.
4. **Respawn:** unchanged (idle while dead; server auto-selects the spawn via §E).

This closes the loop: bots capture points → flag deficit bleeds the losing team → a team hits 0 tickets → match ends. The bot `MATCH_STATE` cache also lets the gate script observe captures and the winner.

---

## H. Perf pre-filter (folded-in follow-up)

`server_main._fire_shot` currently scans the **entire** rewound frame per shot. Conquest clusters players at objectives, raising interest density and per-shot cost (HANDOVER flags p99 already ~33 ms at the budget edge). Fix: reuse the per-tick interest `_grid` (already built for snapshots) to **spatially pre-filter** shot candidates within `weapon.range_m` of the shooter **before** rewind/raycast. Reorder the tick so the grid is populated before `_resolve_fires`, then query neighbors instead of iterating the whole frame. Behavior is unchanged (same hits); only the candidate set shrinks.

---

## I. Server tick integration (`server/server_main.gd`)

Updated `_physics_process` order:
```
poll → _step_movement → _lag.record → (build interest grid)
  → _resolve_fires (now grid-pre-filtered)
  → _handle_respawns (now _select_spawn)
  → _conquest.step(dt, world)        # captures, bleed, win check
  → _send_snapshots (reuses the grid)
  → _maybe_broadcast_match_state     # every 15 ticks; reliable on match end
  → telemetry
```
On `match_over`: broadcast reliable `MATCH_STATE`, log the result (`winner`, tickets, elapsed, captures), and (for the gate) exit after a short drain window.

---

## J. Telemetry additions

Extend the per-second log with: `t0`/`t1` (ticket counts), `pts` (per-point owner summary, e.g. `..0.1.` for A–E), and `cap_events` (owner changes this window). Confirms the match is progressing and surfaces conquest cost under load. Existing M2 counters (kills/shots/hit_rate/tick/starv) stay.

---

## K. Testing

**Unit (headless `TestCase`):**
- `map_def`: loads the v1 JSON; validation rejects missing/short `pos`, `radius<=0`, bad `start_owner`, missing/duplicate team base; `start_owner` default −1.
- `conquest`: neutral→capture (one phase) and enemy→neutralize→capture (two phases); contest freezes progress; multi-attacker rate scaling + `CAP_MAX_ATTACKERS` cap; empty-point decay; bleed by flag deficit (direction + magnitude); death ticket cost; win at `tickets<=0` sets `match_over`+`winner`.
- spawn selection: returns a valid source only (never an enemy/neutral point); picks nearest-to-objective; jitter stays within radius; home-base fallback when no owned points/squadmates.
- squads: fill within team, size cap creates a new squad, leader promotion on leave, ids freed when empty.
- snapshot: round-trip with the new `squad` field + `F_SQUAD` mask.
- protocol: `MATCH_STATE` encode/decode round-trip (owners, cap quantization, tickets, match_over/winner).

**Integration / gate:** `ci/m3_conquest_test.sh` — server (v1 map) + 128 bots across 2 teams; run until `match_over` (or `MATCH_TIME_LIMIT`). Assert: a **winner declared**, **point ownership changed** during the match (real captures, from telemetry/match-state log), **mean tick < 33.3 ms**, and **terminated via tickets** (not the time fail-safe). Record evidence in the milestone doc.

---

## Data flow — capture + match end

```
BOT/CLIENT                                  SERVER (authoritative)
read MATCH_STATE (point owners)
pick nearest non-owned point ─ move ──────▶ pawn pos updated by sim step
stand in radius (alive)                     _conquest.step: count presence per point
                                              one team present + owner!=T → cap += rate*dt
                                              cap>=1 → neutralize (enemy) / capture (neutral)
                                              bleed tickets by flag deficit
kill resolved (existing _fire_shot) ──────▶ tickets[victim.team] -= 1
apply MATCH_STATE (2 Hz) ◀───────────────── broadcast point owners + tickets
                                            tickets<=0 → match_over, winner
apply reliable MATCH_STATE(match_over) ◀──── broadcast once reliably; log + drain + exit
```

---

## Out of scope for M3 (explicit)

Client deploy-screen UI and explicit client-chosen-spawn message (M7, with rendering); squad voice (M6); squad-assigned bot objectives (M3 bots pick individually); class abilities/gadgets; destructible cover affecting capture LoS (M4); map geometry/art (M7); multiple maps / map rotation (one v1 map suffices for the gate); `.tres`/editor map authoring (M7). Movement and gunplay are unchanged from M2.
