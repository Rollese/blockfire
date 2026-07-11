# Blockfire — Handover

Read this first if you're picking up the project in a fresh context. It points to the canonical docs rather than duplicating them. **Status lives in [`docs/TASKS.md`](TASKS.md) — this file deliberately does not restate per-milestone evidence** (a previous version did, went 16 days stale, and taught fresh agents wrong facts).

## What this is
Internal codename for a lightweight, 128-player, low-poly FPS in **Godot 4.7** inspired by *BattleBit Remastered*. v1 game mode: **Conquest**. Three runtime roles in one Godot project (client / dedicated server / bot driver) over a shared core. Repo on GitHub at **Rollese/blockfire** (SSH remote `origin`, default branch `master`). The plan of record is the milestone index in [`docs/TASKS.md`](TASKS.md).

## Status (pointer, correct as of 2026-07-03)
The game is a **playable rendered LAN game**: full infantry loop, vehicles, building/destruction, destructible buildings, ballistics/suppression/melee, squads/FOBs, tactical bot AI, HUD, audio, procedural art. See the milestone index in [`docs/TASKS.md`](TASKS.md) for the authoritative per-milestone state. One-line orientation:

- **Done & gated:** M0–M5.5 (netcode → combat depth II), M11 sim (destructible buildings, Gate A), M12 (FOB/shovel/class refit), M14 (multi-floor, code merged; feel gates pending).
- **In progress:** M7 rendered client (C1–C3 done + ~35 polish increments; human-playtest gate pending), M7.5 bot AI (P2 engine gated; P3 support/survivability done 2026-07-03, drag-to-safety descoped; P4 + free-cam sign-off remain), M8 hardening (P1+P2+P3 done — config + map rotation landed 2026-07-03, see `docs/specs/server-ops.md`; only SIGTERM shutdown remains, recorded infeasible in pure GDScript, deferred).
- **Blocked/deferred:** M6 voice (logic core + Opus GDExtension merged; wiring blocked by M7 gate), M13 Assault (planned), M9/M10 (beta, last).
- **2026-07-02 deep review:** `docs/reviews/2026-07-02-deep-codebase-investigation.md` — six-agent audit, ranked fix batches. **All seven batches executed 2026-07-02→03** (bugs, docs, hardening, perf, extractions, bot-AI §E via batch 6 + M7.5-P3, CI) — see the dated execution notes at the end of the review doc.
- **2026-07-03 goals review:** `docs/reviews/2026-07-03-fable-goals-architecture-review.md` — architecture audit against the owner's three future goals (client perf / low-lag netcode / high-fidelity destruction). Verdict: no change of direction; read §A (settled decisions — don't re-litigate) and §E (execution order: native snapshot encoder ADR first, then player instancing, then hole-aware destruction) **before planning any perf- or destruction-adjacent feature**.

Board: `docs/TASKS.md`. Gates: `docs/milestones/`. Specs: `docs/specs/`. Decisions: `docs/adr/`. Plans: `docs/plans/`. Session logs: `docs/sessions/`. Reviews: `docs/reviews/`. Runbooks: `docs/runbooks/`.

## How we work here (follow this)
The working agreement is `docs/AGENTS.md`. In short:
1. **superpowers skills**, in this order per milestone: `brainstorming` (→ spec in `docs/specs/`) → `writing-plans` (→ `docs/plans/`) → `subagent-driven-development` (execute) → `finishing-a-development-branch` (merge). TDD for every task; `verification-before-completion` before claiming done.
2. **graphify** for architecture/intent questions — the graph (`graphify-out/`, gitignored) covers **both the design docs and the entire GDScript codebase** (`.gd` is indexed as code; see AGENTS.md §1). Query it for "how/why systems relate"; read the `.gd` directly when you need exact current lines. Rebuild with `/graphify --update`.
3. **Branch per work item** (`git checkout -b m8-...`); never implement on `master`. Merge back via finishing-a-development-branch, then **push to `origin/master`** — landing completed *and* checkpoint (spec/plan) work on `origin` is owner-ratified and mandatory; don't strand work on a reclaimable worktree (AGENTS.md §11, §13).
4. Decisions → ADRs; specs precede netcode-bearing code; gates are hard (recorded evidence). **Wire changes**: bump `Protocol.VERSION` and update `docs/specs/wire-protocol-registry.md` in the same commit (next free msg id lives there).

### Execution mechanics that worked well
- **subagent-driven**: dispatch a fresh implementer per task; give substantial/integration tasks a review subagent; the fleet gate is the real integration test. Dispatch review subagents **read-only** and verify `git rev-parse HEAD` after they return (a tool-enabled reviewer once rewound a branch).
- Prove mechanics **deterministically** (`tests/*_test.gd`); don't gate on emergent bot behaviour; combat *feel* is tuned on the rendered client, not blind off telemetry (AGENTS.md §10 — the M5-P1 lesson).
- Balance defaults to **BattleBit's values** (AGENTS.md §9); conservative placeholder values have blocked gates before.

### GDScript / Godot gotchas (tell every implementer)
- Run `godot --headless --path . --import` once after adding any `class_name` script, before tests.
- **Do NOT pipe `godot` through `tail`/`head`** — it can hang; redirect to a file.
- GDScript rejects `var x := <Dictionary access>` (Variant) — annotate the type explicitly.
- Tests live in `tests/*_test.gd` extending global `TestCase`; run `godot --headless --path . -- --test [--filter=<substr>]`. The harness fails a test on: assertion failure, **zero assertions**, a **runtime SCRIPT ERROR mid-test** (opt out with `tolerate_runtime_errors()` when the error path is the point), or a test file that fails to parse. Per-test `setup()`/`teardown()` hooks and `autofree(node)` exist — use `autofree` for any Node you create.
- `git add -A` to include Godot `.uid` sidecars. Commit trailer: co-author as the model doing the work.

## Architecture (current, 2026-07-02)
- `shared/sim/` — deterministic sim core, pure/testable: `World`/`Pawn`/`SimLoop` (30 Hz), `EntityState` (replicated fields + `bake()` quantize cache), movement (stances/lean/jump/stamina, `Ladder`/`Vault`/`Stairs`/`Fall`), combat (`Weapon`/`Combat` seeded rays/`Hitbox`/`projectile.gd` stepped ballistics/`melee.gd`/`armor.gd`/`suppress.gd`/`Grenade` incl. flash+impact), structures (chunked `StructureStore` + `ChunkMask` + `support.gd` collapse cascade + `BuildSite`/`build_site_store.gd` shovel construction + `fob.gd`), vehicles (`Vehicle`/`VehicleState`/`VehicleCatalog`, id space `ID_BASE 0x40000000`), Conquest (`conquest.gd`, `MapDef`, `deploy_spawn.gd` spawn refs), catalogs (`piece_catalog`/`gadget`/`attachment`/`building_catalog`, uniform `{ok, catalog, error}` load contract).
- `shared/net/` — `NetHost` (ENet, channels CONTROL/SNAPSHOT/INPUT/BULK — the reliable BULK channel 3 carries structure traffic), `Protocol` (**VERSION 7**; see [`specs/wire-protocol-registry.md`](specs/wire-protocol-registry.md) for the message table + exact id count — don't restate it here, it moves), `Snapshot` (baseline+delta, ack-keyed per client, ENTER carries armor+weapon), `InputCommand`/`InputBuffer`, `Quantize`. `shared/telemetry.gd` per-second counters ([`specs/telemetry.md`](specs/telemetry.md) is the schema-of-record).
- `server/` — `server_main.gd` (authoritative tick: input → movement → vehicles → lag record → interest → fire/projectiles → ordnance → support → build → respawns → conquest → snapshots; `[perf]` phase buckets), `degrade.gd` (adaptive snapshot degradation ladder), `lag_comp.gd` (mounted-gun rewind only — bullets are present-time projectiles), `spawn_select.gd`, `squads.gd`, voice relay logic shells.
- `client/` — full rendered client: `client_main.gd` (net/prediction/reconciliation/input/QA flags), `world_renderer.gd` (entities, viewmodel, all FX, MultiMesh-batched structures), `hud/` (`hud_model.gd` pure + `hud_view.gd`), `audio/` (director + pure mix helpers, `data/sounds.json`), `art/` (procedural low-poly kits), `menus/` (deploy/squad). ~47 `--*-test` QA flags drive screenshot self-validation (recipes: memory + `docs/runbooks/running-client.md`).
- `bots/` — `bot_driver.gd` (fleet shell: N ENet clients/process + per-milestone gate exercisers) delegating infantry combat/movement to `bots/ai/` (M7.5 engine: `perception.gd` → `utility.gd` → behaviours + `humanize.gd`, per-life `reset()`).
- `native/voice_opus/` — Rust GDExtension Opus codec (M6; binary built locally, source committed).
- `native/snapshot_encoder/` — Rust GDExtension snapshot encoder (ADR-0003; the shipped/default path — `stress.sh` requires the built `.so` unless `ENCODER=gd`). Build: `cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml`.
- Run locally: `docs/runbooks/running-locally.md` (server+client) · fleet/stress: `docker/stress.sh` + `docs/runbooks/running-a-stress-test.md` · telemetry: `docs/runbooks/reading-telemetry.md`.

## Perf & hosts (the short version)
- Tick budget **33.3 ms at 128 players**; recent gates run 14–30 ms peak. `snap` (snapshot encode) is the historical hot path — `EntityState.bake()` (2026-07-01) cut encode 52%; profile `[perf]` before adding per-tick work; degradation knobs + `server/degrade.gd` exist.
- **game2** (`ssh roland@192.168.1.166`, 14900KS) is the full-time dev/gate host — pin the server to **P-cores 0–15** (16–31 are E-cores, AGENTS.md §8). unraid (192.168.1.10) is **production — don't test there**. Client playtest hosts: desktop `.194`, laptop `.128` (agent self-screenshot host).
- Fleet gate how-to: `cd docker && SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./stress.sh` (or a milestone `run-*-gate.sh`). ≤48-bot smokes: `ci/*.sh` on any host. `stress.sh` writes a committable verdict record to `docs/gate-evidence/` — commit it with the closing change. GitHub Actions (`.github/workflows/ci.yml`) runs unit suite + connect smoke on push/PR; the fleet gate stays manual.

## Next
Consult **[`docs/TASKS.md`](TASKS.md)** — currently: M7 human-playtest gate, M7.5 P4 (P3 done 2026-07-03), M6 wiring after M7. All 2026-07-02 deep-review batches are executed (execution notes in the review doc). M8-P3 config + map rotation landed 2026-07-03. Longer-horizon perf/destruction work is prioritized in `docs/reviews/2026-07-03-fable-goals-architecture-review.md` §E.
