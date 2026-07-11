# Deep codebase investigation — 2026-07-02

Full-repo review of all agent-built work to date (M0 → M8/M7.5/M12 era, master `ee7fc93`).
Method: refreshed graphify knowledge graph (4,010 nodes / 5,793 edges), verified the unit
suite green on master (**961 run / 0 failed**), then six parallel read-only review agents:
server core, shared sim/net, client, bots/AI, tests+infra, docs coherence. Everything below
was verified by reading the code (file:line refs are to master `ee7fc93`).

**Overall verdict: no rewrites are warranted anywhere.** All four code reviewers independently
concluded the same thing: the layering discipline (pure static rule modules, stateful stores,
data-driven catalogs, deterministic seeded RNG, TDD) held up remarkably well across ~20 agent
milestones. The debt is concentrated in (a) a handful of real bugs, (b) three god files that
accreted the orchestration the small modules kept out, (c) copy-paste plumbing families, and
(d) badly stale top-level docs. Several findings were independently confirmed by two agents
working different layers (deploy-ref aliasing, `march()` corner tunneling, unbaked vehicle
deltas) — treat those as high-confidence.

---

## A. Confirmed bugs (fix first — all Small effort)

1. **Bot AI preferentially targets immune downed enemies.** `bots/ai/perception.gd:57` skips
   only `not e.alive`; downed pawns keep `alive == true`, and their `hp_frac ≈ 0` makes them
   the *top-priority* target in `bots/ai/behaviors/combat.gd:22`. The reflex loop was
   explicitly fixed for exactly this (`bots/bot_driver.gd:231`, commit `12ba707`) but the fix
   never reached the new M7.5 engine — engage/suppress lock onto an immune body while the
   enemy reviver goes unshot. This plausibly distorts every fleet-gate combat profile since
   2026-07-01. One-line fix + a perception test.

2. **Vehicle seat leak on disconnect.** `server/server_main.gd:2538-2548` erases the client
   and despawns the pawn, but nothing vacates `v.seats` (only `_vehicle_exit`, `_kill_pawn`
   :807-812, and `mark_destroyed` do). Disconnect-while-driving leaves the vehicle
   permanently undrivable and corrupts deploy-screen `free_seats`. Extract the seat-vacate
   block from `_kill_pawn` into `_vacate_seat(p)` and call it on disconnect (also erase
   `_transport_origin` / `_c4[id]`). Add a disconnect-while-driving test.

3. **Remote weapon silhouette goes stale on quick-swap.** `weapon` is replicated ENTER-only
   (`shared/net/snapshot.gd:59`) but is mutable per life via `SWAP_WEAPON` (Msg 32). A remote
   pawn that stays in the interest set renders the wrong held gun from its first swap until a
   LEAVE/ENTER cycle. The delta mask is a full u8, so either widen to u16 or force a synthetic
   LEAVE+ENTER on swap server-side (zero shared-layer change).

4. **Gate scrapers have a live false-PASS vector.** All telemetry scrapes use unanchored
   `grep -oE 'field=[0-9]+'`; `destroyed=` also matches `fobs_destroyed=`, `struct=` matches
   `rstruct=`, `blk=` matches `dropblk=`. The *new* `docker/_gate_lib.sh:38-42`
   (`gate_field`/`gate_peak`/`gate_maxof`) carries the flaw forward, so future gates inherit
   it. A `destroyed>=1` criterion can pass purely off a FOB kill. Fix is one character class:
   `grep -oE '(^| )field=[0-9]+'` in `_gate_lib.sh` + the still-load-bearing scrapes
   (`docker/run-m11-gate.sh`, `ci/m11_buildings_test.sh`); leave frozen-evidence scripts as-is
   with a comment.

5. **Scoreboard rebuilds its whole Control tree every frame while TAB is held.**
   `client/hud/hud_view.gd:813-841` queue_frees and recreates ~650 Controls per *render frame*
   at 128 players (the comment at :786 claiming it's not per-frame is wrong). Pool the 2×64
   rows like the killfeed/compass/squad widgets already do.

6. **Medic aim hijack + give spam.** `bots/bot_driver.gd:861-888`: `_maybe_give` has no
   health check on the mate, fires `GA_GIVE_START` every tick, and unconditionally overwrites
   the bot's yaw/pitch to face the teammate mid-firefight.

## B. Time bombs — must land before M8-P3 (persistent multi-match server)

The one remaining M8-P3 item (config + map rotation, i.e. a long-running server) converts
these from latent to live:

1. **DeploySpawn ref-space aliasing** *(found independently by both the shared and server
   reviewers)*. `server/deploy_spawn` refs use additive bases `SQUADMATE_BASE=200`,
   `VEHICLE_BASE=400`, `FOB_BASE=600` (`shared/sim/deploy_spawn.gd:13-14`) against pawn ids
   assumed "1..128" — but `_next_id` (`server_main.gd:95`) is monotonic and never reused.
   After ~200 cumulative HELLOs since boot, squadmate refs alias into vehicle space
   (`is_valid` checks `>= VEHICLE_BASE` first). Re-base (e.g. 1000/40000 — the wire is
   already u16) or reuse pawn ids via a free-list.

2. **Protocol `VERSION` is theater.** `shared/net/protocol.gd:11` has said `VERSION := 1`
   through dozens of incompatible wire changes; the HELLO check rejects nothing real. The
   de-facto compat mechanism (trailing-byte guards, used 11×) is unsafe inside repeated
   records — `_get_record`'s guard at protocol.gd:241-242 would misalign a multi-record
   baseline from an old encoder. Bump VERSION now, document "bump on any wire change", and
   remove the in-record guards.

3. **Bot-state never resets across lives/matches** (`bots/ai/ai_driver.gd` /
   `perception.gd`: `_memory`, `_enemy_track`, `_last_hp`, `_current_behavior` persist across
   respawn — and would persist across map rotation).

## C. Perf cliffs to schedule (before the next dense-map / high-refresh milestone)

1. **`remotes_at()` clones the entire remote set per call, called up to 4×/frame**
   (`client/interpolation.gd:56-75`; call sites client_main.gd:583/1458/1479/1666). ~23k
   EntityState allocs/sec at 128p for identical within-frame results. Memoize on `now` —
   one-line invalidation on snapshot apply. (S)
2. **Any structure delta triggers a full MultiMesh rebuild of all batches**
   (`client/world_renderer.gd:2341-2407`) — ~8k pieces regrouped per `structs_version` bump.
   A chunk-damage firefight on conquest_town = repeated full-rebuild spikes: the render-side
   twin of the M11 encode cliff already paid for once. Rebuild only affected visual-key
   groups. (M)
3. **`march()` point-sampling tunnels through cell corners and never early-exits**
   *(two agents independently)* — `shared/sim/structure.gd:214,225-235`; all bullet cover,
   rocket, flash-LOS, sledge checks share it. Replace with 3D DDA (Amanatides-Woo) + early
   exit; A/B in a gate run since it's hit-registration-affecting. (M)
4. **Vehicle snapshot deltas are pre-bake-era** *(two agents)* — `snapshot.gd:191-214`
   re-quantizes per field per client per tick, the exact pattern `EntityState.bake()`
   (merge `a5f6e16`) eliminated for pawns. Harmless at 4 vehicles, a trap if counts grow. (M)
5. **Server broadcast fan-outs scan all 128 clients to skip bots** (11 helpers, e.g.
   `server_main.gd:546-614`); `_send_fob_lists` additionally sends reliable FOB_LIST to every
   human *every tick* (:2024-2039), unlike its three changed+heartbeat siblings. Cache a
   `_human_peers` list; throttle FOB_LIST. (S)
6. **Bot driver O(S) structure scans per bot per tick** (`perception.gd:69-71` cover rebuild,
   `_struct_at` full scan `bot_driver.gd:526-530`, sledge/RPG scans). Cell-key the struct
   mirror, incremental cover cache, and implement the spec'd-but-missing `AI_TICK_EVERY`. (M)
7. **Lag-comp records ~129 fresh Dictionaries/tick** (`server/lag_comp.gd:12-17`) though the
   mounted gun is the only remaining rewind consumer. Record only while a gunner exists. (S)

## D. Structural debt — staged extractions (no rewrites)

1. **`server/server_main.gd` (2,592 ln, 121 funcs)** — staged extraction along existing clean
   seams: `stats.gd` (the ~60-counter telemetry wall), `net_send.gd` (11 broadcast helpers +
   human-peer cache — also fixes C5), `fire.gd`, `support.gd`, `build.gd`. Each stage is
   mechanical and covered by existing tests. This also kills the **"mirrors server" test
   class**: 10 test files reimplement server logic locally (e.g. `tests/server_dbno_test.gd`)
   and would silently diverge — extract the mirrored functions and test the real code.
2. **`client/world_renderer.gd` (3,046 ln, 144 funcs)** — extract a transient-FX module
   (shared spawn/age/fade framework + one unshaded-emissive material factory: the same
   material boilerplate is hand-rolled 10×) and cap the uncapped pools (`_puffs`, `_debris`,
   `_blasts`, `_thrown`, `_rockets`). Delete the ~90 lines of grep-verified dead legacy
   structure path (`world_renderer.gd:2545-2629`, `_struct_dying` tick :2311-2320,
   `_struct_rebuilt`).
3. **QA-flag registry** — 47 `--*-test` flags each wired through ~6 copy-paste touch points
   (~350-400 lines total; ~20 near-identical `_ensure_*_demo` clones). One table driving
   configure/wiring + a single `_run_demos(now)` loop.
4. **`bots/bot_driver.gd`** — ~700 of 971 lines are gate exercisers with overlapping
   index-modulo populations (`%8==0/4`, `%5`, `%4`, `%16==4` — the overlaps already halve
   some intended populations, e.g. swap `%4==0` ∩ shovel `%8==4`). Extract to
   `bots/exercisers/` with an explicit role-assignment table.
5. **Protocol codec dedup** — the `pos×10→i16 / dir×10000→i16` packing is copy-pasted in 7
   encoder/decoder pairs (one variant unclamped); two helpers remove ~90 lines. Also: two
   decoders live outside the registry (HELLO inline in server_main.gd:1289, REJECT in
   client_main.gd:934), and `Snapshot._state_byte` (snapshot.gd:34-37) duplicates
   `EntityState.bake`'s packing but is now **test-only dead code** — the tests exercise the
   copy production doesn't use.

## E. Bot AI — beyond the bugs (M7.5 P3/P4 inputs)

- **The flank/spread gap has a concrete, deterministic fix**: `_objective_pos`
  (`bot_driver.gd:906-919`) passes `center == from == me.pos`, neutralizing the centre bias —
  every bot targets its nearest non-owned point, so symmetric maps split into two non-meeting
  columns (the recorded `shots=0` proving_grounds outcome). Fix in `AiObjective`: squad-hash
  pick among top-k candidates + bias toward enemy-owned/contested points + per-bot lateral
  offset in `push_obj`. Assert distribution in pure tests; defer feel to the free-cam gate.
- **Behaviour dynamics bugs**: `incoming_fire` is a 1-tick impulse (`perception.gd:44`) so
  take_cover is a twitch that oscillates with engage; suppress (flat 0.4, no range gate) roots
  wounded bots permanently below ~57% hp; velocity-lead spikes on reappearing enemies
  (`ai_driver.gd:44-52`).
- **Spec'd-but-inert features to either implement or de-document**: `ai_tuning.json`
  `weights` block unread (`utility.gd:14-20` hardcodes), profile hardcoded `"regular"`
  (`bot_driver.gd:87`), perception `_memory` write-only (no last-known suppress), `priority`
  field never populated, `AI_TICK_EVERY` absent, `blackboard.gd`/`commander.gd` scaffolds
  never created, `climb_seek` dropped from the march path in `214b7e4` (ladder nav regression
  — matters for M14 maps).

## F. Testing & ops

- **No automated CI exists** — no `.github/`; `ci/` is 18 manual scripts, only 7 of which run
  the unit suite first. A GitHub Actions job (cache Godot 4.6, `--import` + `--test` +
  connect smoke) closes the gap; the 128-bot fleet stays manual on game2. (M)
- **Gate evidence is not actually committed**: `*.log` is gitignored; the 21 srvlogs (3.9 MB)
  exist only on game2's disk, so AGENTS.md §6 "recorded evidence" is only half-true. Either
  un-ignore them or emit a small committed `gate-evidence-<label>.txt` (verdict + scraped
  numbers + log sha256). (S)
- **Harness upgrades** (S): `assert_ne/gt/contains`, setup/teardown hooks, auto-free of
  Node-derived instances (kills the benign-but-noisy teardown leaks), per-test timing.
  `ci/connect_smoke_test.sh` still uses fixed sleeps (flake-prone); every other script polls.
- **Server phase profiler is too coarse to triage overload**: the `respawn` bucket covers
  twelve subsystems (`server_main.gd:315-328`) — and it's the tool you'd reach for when the
  new degrade ladder trips. Split into proj/ordnance/support/build/respawn. (S)
  Also: `_rewind_clamped` telemetry field is never incremented (dead since M5.5-P1) yet ships
  in the M8-P2 schema-of-record; degrade CLI band `--degrade-high-ms/low-ms` unvalidated
  (inverted band = stride thrash).

## G. Docs — the single worst onboarding hazard

- **`docs/HANDOVER.md` ("read this first") is 16 days stale and would teach a fresh agent
  eight wrong beliefs**: game is headless-only, M4.5 is next, graphify can't parse GDScript
  (directly contradicts AGENTS.md:7), bots are inert, Steam/VAC in M7 scope, pktloss
  unimplemented, plan-of-record at `~/.claude/plans/sorted-plotting-pebble.md` (**file does
  not exist** — same dead pointer in AGENTS.md:79 and README.md:34). Rewrite it (M).
- **TASKS.md dangerous islands** (S): the "bots are inert, don't gate on AI matches" warning
  block (:61) is superseded and actively wrong; M8 row (:22) still lists SIGTERM as open
  (recorded infeasible/deferred 2026-07-01); M11 row (:26) still says dense maps exceed
  budget (fixed 2026-07-01, :58). Malformed M12 row (stray `|` splicing two gate histories);
  M11 row orphaned outside the milestone table; ~60% of the board is closed-work detail that
  belongs in milestone docs.
- **M14 (walkable multi-floor) is invisible** from TASKS/HANDOVER/README despite being merged
  to master with a milestone doc showing unresolved gate rows.
- **Missing docs**: wire-protocol message-id registry (next id = 45 lives only in agent
  memory), post-M7 client architecture map + QA-flag family, degrade-ladder section in the
  telemetry runbook, `specs/server-ops.md` (required by the M8 milestone doc, doesn't exist).
- Housekeeping: `tools/__pycache__/*.pyc` is committed; two stale agent worktrees under
  `.claude/worktrees/` (`m7-p2-audio`, `fix-conquest-spawn-on-contested` — its one unmerged
  commit `b23c01d` is already on master in equivalent form) plus ~10 stale merged branches.

---

## Suggested execution order

| Batch | Contents | Effort |
|---|---|---|
| 1. Bug batch | A1-A6 (downed-targeting, seat leak, weapon delta, gate greps, scoreboard, give-hijack) | ~1 session, S each |
| 2. Docs batch | G: HANDOVER rewrite, TASKS islands + M14 row, protocol registry doc, dead pointers, worktree/branch cleanup | 1 session |
| 3. Pre-M8-P3 hardening | B1-B3 (deploy refs, VERSION, bot-state reset) + F server items — do *before* the map-rotation work | 1 session |
| 4. Perf batch | C1, C5, C7 (S items) then C2/C3/C4/C6 (M items, each gate-verified) | 2-3 sessions |
| 5. Structure batch | D1-D5 staged extractions (server_main first — it unblocks killing the mirror-test class) | opportunistic, per-area |
| 6. Bot AI P3 prep | E: flank/spread fix + behaviour-dynamics fixes, folded into the M7.5-P3 plan | with M7.5-P3 |
| 7. CI | F: GitHub Actions unit+smoke, gate-evidence commits, harness upgrades | 1 session |

Reviewed by six parallel read-only agents; consolidated by the session controller.
Graph refreshed the same day: `graphify-out/` (4,010 nodes, 381 communities).

**Execution note (2026-07-02, batch 5/D1):** stats.gd and the changed+heartbeat state
(reliable_list.gd) were extracted, and the mirror-test class was killed by testing the real
functions through `tests/server_fixture.gd` instead. The remaining D1 items (`fire.gd`,
`support.gd`, `build.gd` wholesale moves) were assessed and **deliberately not done**: those
functions have no clean seam — each touches `_clients`/`_positions`/`_sim`/stats/broadcasts,
so a move means rewriting hundreds of accesses through a back-reference for no testability
gain (the fixture already reaches them directly). The motivations D1 listed (counter wall,
broadcast dedup + human cache, mirror drift) are all addressed. **Superseded 2026-07-03:**
the owner requested the full physical split anyway — `server/fire.gd` / `support.gd` /
`build.gd` now exist (back-ref pattern, server_main 2604→1743 lines).

**Execution note (2026-07-02, batch 5/D4):** the role-assignment table (`bots/roles.gd`,
disjoint by construction + population tests) fixed the real bug — %4==0 (swap) was exactly
%8==0 ∪ %8==4 (the two driller cohorts), so no plain rifleman ever exercised the swap path.
The physical move of exerciser functions was initially skipped, then completed on owner
request 2026-07-03: `bots/exercisers.gd` (driver 987→394 lines). D2 (renderer) likewise
completed in two passes: dead per-piece path deleted + fx_material factory + per-pool caps
(2026-07-02), then the pools/spawn/age physically moved to `client/fx_pool.gd` as a mounted
child node with thin public delegates on the renderer (2026-07-03, world_renderer 3031→2691).
Every stage: suite green, smokes PASS, Xvfb screenshot for renderer changes, and a 128-bot
stress gate over the final state (evidence in `docs/gate-evidence/`).

**Execution note (2026-07-03, batch 6/E):** the flank/spread gap and the behaviour-dynamics
bugs are fixed; this closes the last open batch of this review. `choose_objective_index`
(center==from neutralized the centre bias) is replaced by
`AiObjective.choose_objective_spread` — squad-hash pick across the top-3 nearest capturable
points with a 0.75 distance discount on enemy-owned ground — plus a per-bot lateral march
lane (`spread_march_target`, ±8 m, converging inside 20 m) in the push_obj branch.
Behaviour dynamics: `incoming_fire` is now a decaying envelope
(`Perception.decay_pressure`, 0.97/tick) instead of a 1-tick impulse; suppress is
range-gated (60 m) + hp-scaled so it never outranks engage (the flat 0.4 rooted bots below
~57% HP); enemy velocity tracks restart after a >30-tick visibility gap
(`AiDriver.track_velocity`) instead of averaging across it. The §E "spec'd-but-inert"
list (unread `weights` block, hardcoded profile, write-only `_memory`, `climb_seek` off the
march path, missing `blackboard`/`commander`) remains deferred to the M7.5-P3 milestone
proper — implement-or-de-document per item there. Distribution asserted in pure tests per
the deterministic-testing policy; combat *feel* stays deferred to the free-cam gate.

**Execution note (2026-07-03, §E inert-features / M7.5-P3):** the §E "spec'd-but-inert"
list was executed in full as part of M7.5-P3 (branch `m7.5-p3-support-ai`, support &
survivability): the `ai_tuning.json` `weights` block is finally read by `Utility.score`
(hardcoded values kept as bit-identical defaults, three new keys `revive`/`seek_supply`/
`avoid_danger`); profile `reaction_delay_ticks` honored (was hardcoded 9);
`--ai-profile=<recruit|regular|veteran|elite>` bot-driver flag (validated, fallback
regular); enemy `priority` populated (0.5 when the enemy threatens a revive — within 15 m
of my downed ally; `pick_target` finally consumes the field it always sorted on);
`AI_TICK_EVERY=3` decision cadence implemented (scoring strided, aim/movement every tick,
danger pre-empts only when actually inside a zone — ~3× decision-cost saving);
`Perception.last_known()` — `_memory` is finally read (suppress aims at the last-known
position when no enemy is visible); `climb_seek` re-wired into the push_obj march (the
`214b7e4` ladder-nav regression — matters for M14). The one deliberate exception: the
`blackboard.gd`/`commander.gd` scaffolds stay uncreated **by design** — they are M7.5-P4
(squad & strategy) deliverables, recorded as such in the milestone doc. With batch 6 above,
§E is closed.
