# Blockfire — Handover

Read this first if you're picking up the project in a fresh context. It points to the canonical docs rather than duplicating them.

## What this is
Internal codename for a lightweight, 128-player, low-poly FPS in **Godot 4.6** inspired by *BattleBit Remastered*. v1 game mode: **Conquest**. Three runtime roles in one Godot project (client / dedicated server / bot driver) over a shared core. Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`. Repo on GitHub at **Rollese/blockfire** (SSH remote `origin`, default branch `master`).

## Status (as of 2026-06-14)
- **M0 Foundations** ✅ — repo, docs system, ADRs, connect gate.
- **M1 Netcode core** ✅ — authoritative 30 Hz, per-client baseline+delta snapshots, interest culling, prediction/reconciliation, interpolation, lag-comp substrate. Gate: 128 bots @ ~18 ms tick.
- **M2 Core FPS loop** ✅ — movement (stances/lean/jump/stamina), hit-scan gunplay, lag-compensated head/body hit-reg, health/death/respawn, 2 teams (FF off), minimal classes, combat bot AI. Gate: 128 bots/2 teams, peak-window tick 30.0 ms, kills register. 47 unit tests green.
- **M3 Conquest + deploy/respawn + squads** — **NEXT** (see `docs/milestones/M3-conquest-squads.md`).

Board: `docs/TASKS.md`. Per-milestone gates: `docs/milestones/`. Specs: `docs/specs/`. Decisions: `docs/adr/`. Plans: `docs/plans/`.

## How we work here (follow this)
The working agreement is `docs/AGENTS.md`. In short:
1. **superpowers skills**, in this order per milestone: `brainstorming` (→ write spec to `docs/specs/`) → `writing-plans` (→ `docs/plans/`) → `subagent-driven-development` (execute) → `finishing-a-development-branch` (merge). TDD for every task; `verification-before-completion` before claiming done.
2. **graphify** for architecture/intent questions. NOTE: graphify's extractor **does not parse GDScript** — the graph (`graphify-out/`, gitignored) covers the **design docs only**. Query it for "how/why systems relate"; read the `.gd` directly for code. Rebuild with `/graphify --update`.
3. **Branch per milestone** (`git checkout -b m3-...`); never implement on `master`. Merge back via finishing-a-development-branch, then `git push origin master`.
4. Decisions → ADRs; specs precede netcode-bearing code; gates are hard (recorded evidence).

### Execution mechanics that worked well (M1, M2)
- **subagent-driven**: dispatch a fresh `general-purpose` implementer per task (model `sonnet` is plenty for the well-specified tasks); group trivial independent modules into one dispatch; give the **substantial/integration tasks a review subagent**; the **load-test gate is the real integration test**. Controller-verify trivial modules by reading the committed file.
- Implementers caught several real plan defects (p99 formula, a GDScript `:=` Variant-inference error, a bot no-contact bug, a spread-seed cheat gap). Trust-but-verify; let them flag rather than fake.

### GDScript / Godot gotchas (tell every implementer)
- Run `godot --headless --path . --import` once after adding any `class_name` script, before tests.
- **Do NOT pipe `godot` through `tail`/`head`** — it can hang on first run; redirect to a file.
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly; don't change logic.
- Tests live in `tests/*_test.gd` extending global `TestCase`; run `godot --headless --path . -- --test [--filter=<substr>]`. The harness now **fails any test that runs zero assertions** (catches compile-error false-passes).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. `git add -A` to include Godot `.uid` sidecars.

## Architecture (current)
- `shared/sim/` — `World`(id→Pawn), `Pawn` (kinematic movement, `step(dt, cmd_dict)`, stances/jump/stamina/health/team), `SimLoop` (30 Hz `step(inputs)`, skips dead), `InterestGrid` (uniform spatial hash), `EntityState` (replicated fields), `Stance`, `Weapon` (data-driven), `Hitbox` (head sphere + body capsule ray tests), `Combat` (deterministic seeded ray + damage), `Loadout` (class→weapon).
- `shared/net/` — `NetHost` (low-level ENet transport, channels CONTROL/SNAPSHOT/INPUT), `Protocol` (HELLO/WELCOME/REJECT/INPUT/SNAPSHOT/KILL), `Snapshot` (baseline+delta; `baseline_seq==0`=keyframe resets view), `InputCommand` (look/buttons/view_server_tick), `Quantize`.
- `shared/telemetry.gd` — per-second counters (server logs `[telemetry] ...`).
- `server/server_main.gd` — authoritative tick loop: movement → `LagComp.record` → fire resolution (server reconstructs the ray, **seeded off `_sim.tick`**, never trusts client ray; rewinds enemies to `view_server_tick`; FF-off; head/body hits) → respawns → snapshots → telemetry. `server/lag_comp.gd` history ring.
- `client/` — `client_main.gd` (headless: sends input, applies snapshots, reconciles), `prediction.gd` (movement), `interpolation.gd` (remote lerp).
- `bots/bot_driver.gd` — many bots/process; decode view, acquire enemy by team, aim, hold fire until `ENGAGE_RANGE`, advance to enemy side, respawn.
- Run locally: `docs/runbooks/running-locally.md`. Gates: `ci/connect_smoke_test.sh` (M0), `ci/m1_load_test.sh`, `ci/m2_load_test.sh`.

## Tracked follow-ups (not blocking, address opportunistically)
**Perf (do early in M3 — Conquest will cluster players at objectives, raising interest density; p99 is already ~33 ms at the 33.3 ms budget edge):**
- `server/server_main.gd::_fire_shot` scans the entire rewound frame per shot — reuse the per-tick `_grid` to spatially pre-filter candidates by `range_m` before raycasts.
- Interest recompute is per-client per-tick; consider caching/staggering if density grows (noted since M1).
- The all-clustered-in-one-spot 128p case is the pathological stress scenario that may justify the **ADR-0001 GDExtension escalation** (open ADR-0003 if M3 profiling demands it). Rust toolchain is **not installed**.

**Correctness/robustness:**
- M1: no explicit "stale client hasn't acked in N ticks → force keyframe" beyond bounded-history eviction (which does fall back to a keyframe); ENet packet-loss telemetry not implemented.
- M2: client-side ammo/fire-timer/reload prediction from the spec is **not implemented** (client is a headless stub; comes with rendering in M7). Dead field `trigger_down` in `server_main.gd` (remove). Airborne stamina regen is unrestricted (balance nuance).

**Test/infra:**
- Single bot-driver process can't perfectly feed 128 bots at 30 Hz → nonzero `starv` in telemetry. Acceptable for the gate; production uses many bot containers (M8 Docker). 
- **Docker not installed** (needed for M8). **Rust not installed** (only if GDExtension escalation happens).

## Next: M3 (Conquest + deploy/respawn + squads)
Scope (see `docs/milestones/M3-conquest-squads.md`): data-driven Conquest map (capture points, team spawns), capture/ticket/win logic, deploy screen + spawn-on-point/squad, squad system (create/join, leader, squad spawn), bot AI to path to nearest objective + fight + respawn. Gate: a full **bot-only Conquest match runs start→win at 128 players**, human-spectatable.

**Decisions to brainstorm before the M3 spec** (don't default these silently): ticket/score model + bleed rate; capture mechanics (radius, contest behavior, capture rate, neutralize-then-take vs direct); map data format (where flag positions/spawns live — resource files); squad size + spawn-on-squadmate rules + auto-balance interaction with the existing 2-team assignment; deploy flow; bot objective-selection AI (path to nearest/most-contested point); and how spawns change now that Conquest defines spawn points (M2 used team-half random spawns purely for the gate). Also fold in the perf pre-filter above since objectives will cluster players.

Start by invoking `brainstorming` for the M3 spec.
