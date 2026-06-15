# Blockfire — Handover

Read this first if you're picking up the project in a fresh context. It points to the canonical docs rather than duplicating them.

## What this is
Internal codename for a lightweight, 128-player, low-poly FPS in **Godot 4.6** inspired by *BattleBit Remastered*. v1 game mode: **Conquest**. Three runtime roles in one Godot project (client / dedicated server / bot driver) over a shared core. Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`. Repo on GitHub at **Rollese/blockfire** (SSH remote `origin`, default branch `master`).

## Status (as of 2026-06-15)
- **M0 Foundations** ✅ — repo, docs system, ADRs, connect gate.
- **M1 Netcode core** ✅ — authoritative 30 Hz, per-client baseline+delta snapshots, interest culling, prediction/reconciliation, interpolation, lag-comp substrate. Gate: 128 bots @ ~18 ms tick.
- **M2 Core FPS loop** ✅ — movement (stances/lean/jump/stamina), hit-scan gunplay, lag-compensated head/body hit-reg, health/death/respawn, 2 teams (FF off), minimal classes, combat bot AI. Gate: 128 bots/2 teams, peak-window tick 30.0 ms, kills register. 47 unit tests green.
- **M3 Conquest + deploy/respawn + squads** — **gameplay ✅ · 128-bot perf gate BLOCKED (hardware)**. Data-driven map (`MapDef`), Conquest state machine (`ConquestState`: capture/neutralize/contest, ticket bleed + death cost, win), squads (`SquadManager`), server-authoritative deploy/respawn spawn selection (`SpawnSelect`), `MATCH_STATE` broadcast, fire pre-filter, bots that path/capture/fight/reload to a decisive win. **Gate 2026-06-15: gameplay PASS at 128** (`[match] OVER winner=0 elapsed=217s cap_events=2`, ended via tickets); **full gate PASS at 48 bots** (tick 19.7 ms < 33.3). **128-bot tick budget FAILS on this laptop** (106 ms — thermal throttle; M2 also fails the budget on this box today; M3 == M2 per-tick cost). Outstanding to close: validate the 128-bot tick budget on the **separate-host bot fleet** (server uncontended). 88 unit tests green. See `docs/milestones/M3-conquest-squads.md` + `docs/specs/m3-bot-convergence-fix.md`.
- **M4 Building & destruction** — gated behind M3's 128-bot perf validation (per the working agreement, don't start before the prior gate fully passes).

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
**Perf / the M3 128-bot blocker (do before declaring M3 fully closed):**
- **128-bot server tick is hardware-bound on this laptop.** Under sustained 128-bot load the 4750U throttles (95 °C, ~1.4 GHz) → server tick 50–106 ms vs 33.3 ms budget. M3 == M2 per-tick cost; M2 also fails on this box today. The real validation needs the **separate-host bot fleet** (`bots/bot_driver.gd` already supports `--connect=<ip>`) so the server core runs uncontended — this is the one thing left to close M3's gate. Ties into ADR-0001 (GDExtension escalation — only if a *cool, uncontended* box still breaches) and M8 (Docker bot fleet). Rust **not installed**; Docker **not installed**.
- The M3 fire pre-filter (`_fire_shot` reuses the per-tick `_grid` to broad-phase candidates) is **done** (Task 9). Interest recompute is still per-client per-tick — consider caching/staggering if density grows (noted since M1).

**Correctness/robustness:**
- M3: `server_main.gd::_build_interest` builds the interest grid before respawns (so the fire pre-filter can reuse it), so a pawn that respawns mid-tick has **one-tick-stale interest-set membership** in that tick's snapshots (position data itself is fresh; self-corrects next tick). Documented in code; accepted to keep the grid single-build per tick.
- Bots are **ammo-blind** (no client ammo prediction). They reload via a server-time burst heuristic (`bot_driver.gd` `BURST_TICKS`/`RELOAD_TICKS`); fine for the fleet but coarse — real ammo/reload prediction comes with rendering (M7).
- M1: no explicit "stale client hasn't acked in N ticks → force keyframe" beyond bounded-history eviction (which does fall back to a keyframe); ENet packet-loss telemetry not implemented.
- M2: client-side ammo/fire-timer/reload prediction not implemented (headless stub; comes with rendering in M7). Dead field `trigger_down` **removed** in M3. Airborne stamina regen unrestricted (balance nuance).

**Gameplay (M3):**
- A symmetric bot match is decided by **combat attrition (death-tickets), not flag bleed** — mirror bots hold backfield 1–1 so no flag deficit forms. Flag capture/bleed is implemented and exercised but doesn't swing a symmetric match. For real bleed-driven matches, add **flank/spread bot objective AI** (avoid piling all bots onto the contested centre; attack under-defended enemy points). Tracked, not blocking the gameplay gate.
- Single bot-driver process can't feed 48+ bots at 30 Hz from one host → high `starv` and slowed bot reactions at scale; another reason the 128-bot validation wants the multi-host fleet.

## Next
- **Close M3:** run `ci/m3_conquest_test.sh` with bots on a **separate host** (`--connect`) to validate the 128-bot tick budget uncontended. That is the only outstanding gate criterion (gameplay already passes at 128).
- **Then M4 (Building & destruction)** — gated behind M3's perf validation. Start with `brainstorming` → spec, per the working agreement.
