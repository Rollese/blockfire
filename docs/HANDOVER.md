# Blockfire — Handover

Read this first if you're picking up the project in a fresh context. It points to the canonical docs rather than duplicating them.

## What this is
Internal codename for a lightweight, 128-player, low-poly FPS in **Godot 4.6** inspired by *BattleBit Remastered*. v1 game mode: **Conquest**. Three runtime roles in one Godot project (client / dedicated server / bot driver) over a shared core. Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`. Repo on GitHub at **Rollese/blockfire** (SSH remote `origin`, default branch `master`).

## Status (as of 2026-06-15)
- **M0 Foundations** ✅ — repo, docs system, ADRs, connect gate.
- **M1 Netcode core** ✅ — authoritative 30 Hz, per-client baseline+delta snapshots, interest culling, prediction/reconciliation, interpolation, lag-comp substrate. Gate: 128 bots @ ~18 ms tick.
- **M2 Core FPS loop** ✅ — movement (stances/lean/jump/stamina), hit-scan gunplay, lag-compensated head/body hit-reg, health/death/respawn, 2 teams (FF off), minimal classes, combat bot AI. Gate: 128 bots/2 teams, peak-window tick 30.0 ms, kills register. 47 unit tests green.
- **M3 Conquest + deploy/respawn + squads** ✅ — Data-driven map (`MapDef`), Conquest state machine (`ConquestState`: capture/neutralize/contest, ticket bleed + death cost, win), squads (`SquadManager`), server-authoritative deploy/respawn spawn selection (`SpawnSelect`), `MATCH_STATE` broadcast, fire pre-filter, bots that path/capture/fight/reload to a decisive win. **Gate 2026-06-15 PASS at 128 on the separate-host fleet** (unraid W-2275, server pinned to isolated cores + bots in Docker, `docker/`): `winner=0 elapsed=289s cap_events=7 peak tick=28.62ms < 33.3`. Closing it needed a **snapshot-cost fix** — profiling showed `_send_snapshots` was ~88% of the tick (O(N²) delta-encode when clustered); `SNAPSHOT_STRIDE=2` (15 Hz sends) + `MAX_SNAPSHOT_ENTITIES=32` (enemy-prioritized relevance cap) took the peak 95 → 28.6 ms. 48-bot laptop gate also PASS (19.7 ms). 88 unit tests green. See `docs/milestones/M3-conquest-squads.md`, `docs/specs/m3-bot-convergence-fix.md`, `docker/README.md`.
- **M4 Building & destruction** ✅ — **Both phases gate PASSED 2026-06-15; M4 CLOSED.** Phase 1 (Building): place/remove, event-based replication, coarse cover + movement collision. Phase 2 (Destruction): bullet damage to pieces (remove at 0 HP), bucketed (75/50/25%) partial-health replication via `STRUCTURE_DELTA(OP_DAMAGE)`, server-side thrown grenades — **frag** (present-time area damage to structures + pawns, FF-off, no rewind) and **smoke** (server zones + `SMOKE_DEPLOYED`, no damage until M7 LOS culling) sharing one `Grenade` ballistic model. Specs `docs/specs/building.md` + `docs/specs/destruction.md`; plans `…m4-building.md` (15 tasks) + `…m4-destruction.md` (14 tasks); **140 unit tests green**. **Laptop-48 PASS** + **fleet-128 PASS (2/2 reruns)** on the unraid W-2275 Docker fleet: `winner valid, elapsed 233/272s, destroyed=5/23 nades=88/55 smoke=128, peak tick=29.48ms < 33.3`. Per-phase `[perf]` confirms destruction is cheap (`_step_grenades`/smoke fold into respawn=0.1ms; bucket deltas capped at 64/tick in snap); `snap` (~16ms pre-existing M3 snapshot) stays the dominant cost. (One earlier fleet run spiked to 35.39ms — a contention outlier; the tick rides the budget edge at 128, a carried watch item.) Degradation knobs: `MAX_STRUCTURE_DELTAS_PER_TICK`, `MAX_BOT_GRENADES`/`MAX_BOT_SMOKES`, `BLAST_STRUCT_RADIUS`. See `docs/milestones/M4-building-destruction.md`. **Next milestone: M4.5 Combat Depth.**

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
**Perf (128-bot gate now passes — context for M4+):**
- **128-bot perf is validated on the local game2 Docker fleet** (as of 2026-06-16; game2 = 14900KS, the full-time dev+gate host — a laptop only attaches to a tmux session on it). Run the fleet locally on game2 (`docker/`, server pinned to **P-cores** via `cpuset`, bots in containers via `--connect`) — no cross-host ssh. Reproduce: `cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-m4.5-p3-gate.sh`. **Pin the server to P-cores only (logical 0–15); 16–31 are slower E-cores** (see AGENTS.md §8). The ≤48-bot smoke also runs on game2 (`ci/m4.5_p3_test.sh`). (Historical note: the old 4750U laptop thermally throttled at 128 and earlier gates ran on the unraid W-2275 fleet — unraid is now production, don't test there.)
- **`_send_snapshots` is the tick hot path** (was ~88% / O(N²) when clustered). Now bounded by `SNAPSHOT_STRIDE=2` (15 Hz sends) + `MAX_SNAPSHOT_ENTITIES=32` (enemy-prioritized relevance cap). Per-phase `[perf]` telemetry is in `_log_telemetry` — **re-profile if M4/M5 tick cost regresses.** ADR-0001 GDExtension is the next lever only if a cool/uncontended box breaches *after* algorithmic tuning (it didn't for M3). The 14900K dedi (when ready) is the best server host (single-thread headroom).
- These netcode params (15 Hz snapshots, 32-entity relevance budget) are deliberate, tunable tradeoffs — revisit for the real (rendered) client in M7.
- The M3 fire pre-filter (`_fire_shot` reuses the per-tick `_grid`) is done. Interest recompute is still per-client per-tick — cheap (<200 µs), not currently a concern.
- Docker now **installed on unraid** (Compose v5.1.2); the run-from-source image (`docker/Dockerfile`) is the M8 fleet bootstrap (export-based production variant deferred — see `docker/README.md`). Rust still **not installed** (only for a future GDExtension escalation).
- The 128-bot run showed `starv` rise once the server keeps full 30 Hz (the fleet can't supply 128 inputs that fast from 4 containers) — raise `BOT_REPLICAS` if it matters; not a gate criterion.

**Correctness/robustness:**
- M3: `server_main.gd::_build_interest` builds the interest grid before respawns (so the fire pre-filter can reuse it), so a pawn that respawns mid-tick has **one-tick-stale interest-set membership** in that tick's snapshots (position data itself is fresh; self-corrects next tick). Documented in code; accepted to keep the grid single-build per tick.
- Bots are **ammo-blind** (no client ammo prediction). They reload via a server-time burst heuristic (`bot_driver.gd` `BURST_TICKS`/`RELOAD_TICKS`); fine for the fleet but coarse — real ammo/reload prediction comes with rendering (M7).
- M1: no explicit "stale client hasn't acked in N ticks → force keyframe" beyond bounded-history eviction (which does fall back to a keyframe); ENet packet-loss telemetry not implemented.
- M2: client-side ammo/fire-timer/reload prediction not implemented (headless stub; comes with rendering in M7). Dead field `trigger_down` **removed** in M3. Airborne stamina regen unrestricted (balance nuance).

**Gameplay (M3):**
- A symmetric bot match is decided by **combat attrition (death-tickets), not flag bleed** — mirror bots hold backfield 1–1 so no flag deficit forms. Flag capture/bleed is implemented and exercised but doesn't swing a symmetric match. For real bleed-driven matches, add **flank/spread bot objective AI** (avoid piling all bots onto the contested centre; attack under-defended enemy points). Tracked, not blocking the gameplay gate.
- Single bot-driver process can't feed 48+ bots at 30 Hz from one host → high `starv` and slowed bot reactions at scale; another reason the 128-bot validation wants the multi-host fleet.

## Next
- **M4.5 Combat Depth & class identity** ✅ — **all three phases CLOSED (P1 2026-06-15, P2 + P3 2026-06-16); M4.5 COMPLETE.** P3 (Movement: ladder climbing, auto-vaulting, drop-shoot prevention) gated PASS on game2 (`winner=1 climbs=9 vaults=16 peak tick=23.46ms<33.3`, evidence `docker/srvlog-20260616-115725.log`). Movement rules live in `shared/sim/` (`Ladder`/`Vault` + `SimLoop`); `climbing` replicated in state-byte bit 7 (`vaulting` + body-drag deferred to M7). 245 unit tests green. See `docs/milestones/M4.5-combat-depth.md`.
- **Next milestone: M5 — Vehicles (land + air).** Needs the RPG (built in M4.5-P2) for anti-vehicle play and wires the Engineer repair kit (defined in M4.5) to a new vehicle HP system. **Watch the tick budget:** the 128-bot fleet peak rides the edge (~23–29 ms across milestones) and `snap` (~16 ms) is the dominant pre-existing cost — profile `[perf]` on the fleet early and lean on the degradation knobs (`MAX_STRUCTURE_DELTAS_PER_TICK`, gadget caps) before adding per-tick work.
- **Fleet gate how-to (local on game2, no ssh):** `cd /home/roland/projects/blockfire/docker` then run the milestone's gate script with the server pinned to **P-cores** — e.g. `SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-m4.5-p3-gate.sh`. Per-milestone gate scripts: `run-gate.sh` (M3), `run-m4-gate.sh` (M4), `run-m4.5-p2-gate.sh` (P2 combat depth), `run-m4.5-p3-gate.sh` (P3 movement: `climbs>=1`, `vaults>=1`, valid winner, peak tick<33.3, agg bw reported). Each writes a persisted `srvlog-<ts>.log` as recorded evidence. **Server on P-cores only (0–15); 16–31 are E-cores** (AGENTS.md §8). If a fleet match over-blocks, lower `MAX_BOT_BUILDS`/`MAX_BOT_GRENADES` in `bots/bot_driver.gd`.
