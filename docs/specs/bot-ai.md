# Spec: Bot Intelligence (Tactical AI) — M7.5

**Status:** brainstorm-of-record (owner-approved design, 2026-06-18) · **Milestone:** [`M7.5-bot-intelligence.md`](../milestones/M7.5-bot-intelligence.md)

This is the build contract for M7.5. Where this spec and the milestone doc differ, **this spec wins**. It
covers the whole milestone (P1–P4) as the design of record, then defines precisely what the **current
headless increment** builds and how it is proven.

---

## 1. Purpose

Replace today's reflex bots (`bots/bot_driver.gd`: "fight the nearest enemy") with tactical, **human-like,
fair-play** infantry AI good enough to backfill real 128-player Conquest matches alongside and against
humans. Bots reason only from their interest-managed snapshot view, behave believably (reaction delay,
imperfect aim), and stay anti-cheat-clean (ordinary validated inputs; human-shaped behaviour distributions
that do not trip Layer-4 — see [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md)).

## 2. Scope

### 2.1 This increment (headless, buildable now)

- **Full rewrite** of `bot_driver.gd` into a layered `bots/ai/*` engine; the reflex "nearest-enemy" brain
  is **retired**.
- **P2 — Individual combat IQ** is the new/redesigned content: perception + short-term memory + reaction
  gate, target prioritization, stop-to-shoot, cover-seek + crouch/prone, peek-fire-retract, threat-aware
  retreat, suppressive fire, frag-vs-cover.
- **Re-home (carry over, do not redesign)** the existing **gadget**, **driller**, and **vehicle-crew**
  behaviours into the new module layout so **every closed M3/M4/M4.5/M5 fleet gate stays green**. Vehicle
  crew is explicitly **preserved for the M5 gate only** and is **not** part of M7.5's infantry AI scope.
- **Determinism + budget + match-completion** are the hard headless gate; tactical-quality counters are
  **reported, not gated** (AGENTS.md §10).

### 2.2 Deferred to post-M7 (needs the rendered client)

- **P1 observability** — admin free-fly spectator, bot-AI debug overlay, follow/possess, the admin-only
  debug intent channel. (Designed in §10 for completeness; not built this increment.)
- **Feel-tuning** of the utility-curve weights and difficulty profiles — tuned by the operator watching
  matches on the renderer, never blind off telemetry (AGENTS.md §10).
- **P3 support intelligence** and **P4 squad strategy** as *new tactical quality* (their existing behaviours
  are re-homed now; the smarter versions land in later increments).

## 3. Standing constraints (ratified)

1. **Fair-play perception.** Bots use **only the interest snapshot** a real client receives (already true).
   No omniscience, no server-internal reads.
2. **Human-like conduct.** Reaction delay, aim-error cone + settle, and attention limits are first-class and
   tunable. Bots must read as human to Layer-4 detection and under the (future) free-cam.
3. **AI is client-side.** All decision-making runs in the **bot-driver processes, off the 30 Hz server
   tick**. AI stays **out of `shared/`** (a pure cover-query helper may live in `shared/` only if the future
   client debug overlay must reuse the same math).

## 4. Architecture

Five layers, all bot-driver-side. `bot_driver.gd` becomes a thin **fleet shell**; per-bot decision-making
moves into `bots/ai/`.

```
bots/bot_driver.gd        fleet shell: connect, poll, decode packets, hold per-bot state, send input.
                          Delegates each bot's per-tick decision to AiDriver.
bots/ai/
  ai_driver.gd            per-bot orchestrator. Every AI_TICK_EVERY ticks: perception -> decision ->
                          execution. Between AI ticks the active behaviour FSM keeps emitting primitives.
  perception.gd           builds the WorldModel from the snapshot view (+ vview/structs/match_points),
                          maintains short-term memory (decaying last-known enemy positions) and the
                          reaction-delay gate (a freshly-seen enemy is not actionable for N ticks).
  world_model.gd          data: visible enemies/allies/downed-allies/cover/objective states + memory.
  blackboard.gd           squad-shared knowledge (spotted / focus-fire / support requests). Scaffold this
                          increment; populated in P4.
  utility.gd              behaviour scoring (tunable curves) + argmax with hysteresis (anti flip-flop).
  humanize.gd             seeded reaction / aim-error cone + settle-time / attention model.
  behaviors/
    combat.gd             P2 NEW  stop-to-shoot, target priority, suppressive fire, frag-vs-cover.
    cover.gd              P2 NEW  cover selection, crouch/prone, peek-fire-retract, threat-aware retreat.
    support.gd            P3      re-homed revive / give / bag logic (carried over, not redesigned).
    objective.gd          P4      re-homed objective-selection / build / mine logic (carried over).
    vehicle_crew.gd       re-homed M5 crew (enter/drive/repair). PRESERVED FOR M5 GATE; not M7.5 AI scope.
    drill.gd              re-homed driller exerciser (M4.5-P3 climbs/vaults gate artifact).
data/ai_tuning.json       NEW  utility weights + difficulty profiles (Recruit/Regular/Veteran/Elite).
ci/m7.5_ai_test.sh        NEW  headless gate (telemetry asserts + bot-driver CPU scaling).
```

**Helper migration.** The unit-tested static helpers currently on `BotDriver`
(`choose_objective_index`, `climb_seek`, `drill_step`, `combat_button`, `apply_structure_delta`,
`vehicle_is_enemy`, `nearest_enemy_vehicle`, `nearest_free_vehicle`, `drive_toward`,
`central_point_index`, `nearest_enemy_pos`, `enemy_spawn_pos`) **move verbatim into the matching `ai/`
module** and their existing tests move with them. No logic change → the 466-test baseline stays green.

## 5. Data model

### 5.1 WorldModel (per bot, rebuilt each AI tick)

Derived **only** from `view` (id→`EntityState`: pos/alive/team/stance/yaw/`is_downed`), `vview`
(vehicles), `structs` (structure mirror), `_match_points` (flag ownership), and `server_tick`:

- `enemies` — visible alive enemies: `{id, pos, stance, dist, last_seen_tick}`.
- `allies` — visible alive teammates; `downed_allies` — `is_downed` teammates.
- `cover` — candidate cover from known structures + (later) terrain; coarse cell-centre positions as today.
- `objectives` — capture-point positions + ownership from `_match_points`.
- `incoming_fire` — inferred pressure signal (see §6.1).
- `self` — my `EntityState` + per-life flags.

### 5.2 Short-term memory + reaction gate (in `perception.gd`)

- **Memory:** when an enemy leaves view, retain its last-known `{pos, tick}` for `MEMORY_DECAY_TICKS`;
  used to drive suppressive fire and search. Decayed entries are dropped.
- **Reaction gate:** a newly-perceived enemy records `first_seen_tick`; it does **not** become an
  actionable combat target until `now - first_seen_tick >= REACTION_DELAY_TICKS` (profile-scaled). This is
  the human-reaction model and a Layer-4 fairness lever.

### 5.3 Blackboard (squad-scoped; scaffold now)

Shared among squadmates (models squad voice comms): `spotted[]`, `focus_target`, role assignments,
`need_medic` / `need_ammo`. Created and wired this increment as an empty/no-op surface so P4 can populate it
without re-plumbing; it has **no gameplay effect** until P4.

## 6. Decision layer

`utility.score(world, profile) -> {behavior, score}[]`, argmax wins, with **hysteresis**: the current
behaviour gets a stickiness bonus so the bot does not flip-flop per tick. Initial curves (tuned later on the
renderer):

```
score(take_cover)   = f(incoming_fire, 1 - health_frac, cover_nearby)
score(retreat)      = f(health_frac < RETREAT_HP_FRAC, threat)
score(revive)       = f(downed_ally_near, threat_low, role)        # P3 behaviour, re-homed
score(suppress)     = f(enemy_last_known, ammo, squad_focus)
score(push_obj)     = f(obj_contested, role == ATTACK)             # P4 role; default ATTACK this increment
score(defend_obj)   = f(obj_owned_threatened, role == DEFEND)
score(engage)       = f(actionable_target, in_range)
  -> argmax (with hysteresis) -> behaviour FSM -> humanized primitives
```

### 6.1 Incoming-fire / suppression signal

A bot has no server "I'm being shot at" flag. Infer pressure from observables: recent **health drops**
between snapshots, and enemies **aiming at me** within a cone at range. This drives `take_cover` /
`retreat` utility and (later) the suppression FX source. Defined as a pure function over consecutive
WorldModels so it is unit-testable.

## 7. Behaviour catalog

**P2 — individual combat IQ (NEW this increment)**

- **Stop-to-shoot** — zero/minimise movement while firing (the server adds movement spread).
- **Target prioritization** — not "nearest": prefer low-HP, reviving medics, flag-cappers, and whoever is
  actively shooting this bot; tie-break stable by id.
- **Cover-seek + stance** — under fire / low HP, move to nearest cover and **crouch or prone**;
  **peek → fire → retract**. Respects the M4.5 drop-shoot fire-gate.
- **Threat-aware retreat** — below `RETREAT_HP_FRAC`, break contact toward cover.
- **Suppressive fire** — keep firing at an enemy's **last-known** position (from memory) to pin a ducked
  target.
- **Frag-vs-cover** — throw a frag when a structure sits between the bot and a clustered/entrenched enemy
  (reuses the existing `_cover_between` geometry).

**P3 — support & survivability (re-homed now; smarter later)**

Revive (medic-priority), self-state handling when downed, medic/ammo bag deploy + use, grenade/mine
avoidance, ladder/vault navigation. Existing heuristics carried into `support.gd` / `objective.gd`.

**P4 — squad & strategy (scaffold now; built later)**

Commander ATTACK/DEFEND roles, focus fire, spacing/anti-bunch + flanking, defensive emplacements, dynamic
rebalancing. Blackboard + commander populated in a later increment.

## 8. Humanization & difficulty

`humanize.gd` wraps every emitted primitive with: **reaction delay** (gated in perception), **aim-error
cone** + **settle time** (error converges onto a tracked target over `AIM_SETTLE_TICKS`), and an
**attention** limit (how many threats a bot tracks). Packaged into named **difficulty profiles**
(Recruit / Regular / Veteran / Elite) as data bundles in `data/ai_tuning.json`. This is also the anti-cheat
story: human-shaped hit-rate and behaviour distributions keep Layer-4 from flagging bots.
**Difficulty → ADR-0004 skill-tier mapping is deferred to M9**; M7.5 exposes the knobs only.

**Known balance gap (2026-07-06 playtest) — bot RPG-at-structure aggression (deferred to a balance pass).** Engineer bots fire RPGs freely, and over a long match their splash + misses chew the map heavily: an owner playtest measured ~**815 rockets in 28 min** across ~24 bots → ~**27 %** of `conquest_town`'s pieces destroyed and **12 building collapses**, so a player joining a mature match dropped into a heavily-wrecked map. This is *not* a correctness bug (it's cumulative live combat), but the **rate is high and un-BattleBit-like**. A future balance pass should temper Engineer RPG usage vs. structures — e.g. prefer RPGs against vehicles/fortified positions, cap structure-directed rocket cadence, or gate RPG fire behind a real (non-structure) target — tuned alongside the §11 constants / difficulty profiles. Until then, `--fast-rpg` and `--fast-nades` are **humans-only** (bots keep the normal cooldowns) so QA destruction-testing doesn't compound this.

## 9. Determinism & RNG

- **All** humanization/decision randomness comes from a **per-bot seeded `RandomNumberGenerator`**
  (`seed = global_seed XOR bot_index`). No bare `randf()` in any decision/aim path.
- Tests inject a fixed seed (or disable humanization) so behaviour selection and emitted primitives are
  **reproducible** — this is what makes the "provable decision" tests deterministic.
- The global seed is logged at bot-driver start for repro of a fleet run.

## 10. Spectator & observability (P1 — designed, deferred to post-M7)

Documented so the data path is forward-compatible; **not built this increment.**

- **Server:** an **admin SteamID allowlist** in config; a **spectator role** the server treats as
  non-combat and **exempts from movement validation + excludes from Layer-4 statistics**, so free-flying
  cannot self-flag. Free-cam is a sanctioned built-in mode (VAC-safe).
- **Client (on M7's renderer):** an F-key (default **F9**, rebindable) toggles free-fly; bot-AI debug
  overlay (role / state / target / chosen-cover / intent gizmos); follow/possess a bot.
- **Debug data path:** bots publish a compact **intent packet** (role, state, target_id, cover_pos) over an
  **admin-only debug channel** relayed only to admin spectators; dev-only, disabled in production builds.

No new wire messages are required for the **P2 headless increment** — bots send only the existing
`InputCommand` + gadget/build/revive/vehicle messages.

## 11. Constants (initial; gate/feel-tuned later)

| Const | Value | Meaning |
|---|---|---|
| `AI_TICK_EVERY` | 3 | run the decision layer every N ticks (bot-driver CPU knob) |
| `REACTION_DELAY_TICKS` | 9 (~0.3 s) | ticks before a newly-seen enemy is actionable (profile-scaled) |
| `AIM_ERROR_DEG` | 3.0 | base aim-cone half-angle before settle (profile-scaled) |
| `AIM_SETTLE_TICKS` | 6 | ticks for aim error to converge onto a tracked target |
| `MEMORY_DECAY_TICKS` | 90 (3 s) | last-known enemy position lifetime |
| `COVER_SEEK_HP_FRAC` | 0.5 | health fraction below which cover-seek utility spikes |
| `RETREAT_HP_FRAC` | 0.25 | health fraction below which retreat dominates |
| `HYSTERESIS_BONUS` | tuned | stickiness added to the current behaviour's score |
| `SPECTATOR_FLY_KEY` | F9 | client free-fly toggle (P1, deferred) |

## 12. Budgets

- **Server tick:** essentially unaffected — AI is client-side. (Spectator pawn + debug relay are admin-gated
  and deferred.)
- **Bot-driver CPU (the new budget):** AI runs at `AI_TICK_EVERY` cadence; `[bot-perf]` telemetry logs mean
  AI-decision µs/tick and bots/process. Degrade gracefully (raise cadence / simplify scoring) **before**
  dropping bot count.
- **Bandwidth:** no new per-tick stream this increment.

## 13. Edge cases

- **No target / nothing seen** — fall back to objective march (re-homed selector); suppress last-known if
  memory still warm.
- **Downed self** — hold; immune-DBNO model preserved (no self-bandage that would stall the match).
- **Reaction gate vs. already-engaged** — a target already past the gate stays actionable while continuously
  visible; the gate re-arms only after the enemy is lost for longer than memory decay.
- **Hysteresis vs. emergencies** — `retreat`/`take_cover` ignore stickiness when `incoming_fire` is high or
  HP is below `RETREAT_HP_FRAC` (survival overrides commitment).
- **Re-homed behaviours unchanged** — gadget/driller/vehicle keep their existing trigger logic so legacy
  gate counters fire exactly as before.

## 14. Test plan

**Approach: pure-decision tests + one thin wiring test** (chosen over heavy headless integration — faster,
deterministic, matches AGENTS.md §10).

- **Behaviours** (`tests/ai_combat_test.gd`, `tests/ai_cover_test.gd`): feed a synthetic `WorldModel`,
  assert the **argmax behaviour** and the **emitted input primitive** (e.g. under fire @40% HP → `seek_cover`
  emits crouch + move-to-cover; reviving-medic outranks nearest in target priority).
- **Utility** (`tests/ai_utility_test.gd`): scoring monotonicity + hysteresis (no per-tick flip-flop).
- **Perception** (`tests/ai_perception_test.gd`): memory decay; reaction gate timing; incoming-fire
  inference from consecutive WorldModels.
- **Humanize** (`tests/ai_humanize_test.gd`): seeded reproducibility; aim error settles within
  `AIM_SETTLE_TICKS`.
- **Wiring** (`tests/ai_driver_test.gd`): one headless scenario drives perception→decision→primitive
  end-to-end on a hand-built view dict.
- **Re-homed helpers**: keep their existing tests (moved with the code).
- **Harness rule honoured**: every test runs ≥1 assertion (zero-assertion = fail).

## 15. Gate

**Headless gate this increment** (`ci/m7.5_ai_test.sh` ≤48-bot smoke + a 128-bot `docker/` fleet run). The
reflex brain is retired, so the new AI is the only driver — there is no opt-in flag:

- **Hard:** 128 bots sustained on the new AI driver; **server tick mean < 33.3 ms**; bot-driver CPU scales to 128;
  Conquest **reaches a winner**; **all legacy gate scripts still pass** (M3/M4/M4.5/M5 counters intact).
- **Reported, not gated:** cover-occupancy / stance-change, stop-to-shoot %, suppression events,
  frag-vs-cover throws, target-priority hits, humanized hit-rate distribution.

**The real milestone gate — operator visual sign-off via the free-cam — remains deferred to post-M7**
(AGENTS.md §10). This increment cannot close M7.5; it lands the proven engine.

## 16. Explicit non-scope

- **Bot vehicle operation AND vehicle response** — bots neither drive/pilot nor *react to* vehicles in v1
  (vehicle-crew is re-homed only to keep the M5 gate green, behind the existing crew gating).
- **ML / RL** — utility curves are hand-authored and data-tuned.
- **Bots using M6 voice** — coordination is the blackboard only.
- **Navmesh overhaul** — reuse existing navigation.
- **Difficulty → skill-tier mapping** — deferred to M9.
- **Spectator time-controls / capture** — cut as YAGNI.

## 17. Open follow-ups

- Cover detection is coarse (structure cell-centres, as today); richer cover (terrain, AABB-aware) is a
  later refinement.
- Incoming-fire inference is heuristic; revisit once the renderer lets the operator judge whether bots
  "feel" appropriately pressured.
- Retiring vehicle-crew from the bot fleet entirely depends on a future vehicle-bot decision (currently
  preserved solely for the M5 gate).
