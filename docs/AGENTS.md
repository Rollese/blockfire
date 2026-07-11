# Working Agreement for Agents

This project is built largely by AI agents. Follow these rules so we stay coordinated and don't trample each other's work.

## 1. Explore the code with graphify, not by reading files manually

**From now on, every agent explores this codebase through `graphify` first — not by opening, grepping, or scanning files by hand.** As of 2026-06-15 the entire GDScript codebase (`.gd`) is indexed as **code** alongside the docs, so the knowledge graph in `graphify-out/` covers classes, functions, methods, call graphs, and `extends` inheritance across `shared/`, `client/`, `server/`, `bots/`, and the test suites — not just the design docs.

Rules:

- **Default to a graphify query.** Any question about architecture, file relationships, call flow, or "where does X happen / what calls Y / what extends Z" is a **`graphify query "…"` first**, not a manual file hunt and not a guess.
- **The graph already exists.** When `graphify-out/graph.json` is present, query it directly — do not re-scan or rebuild for a read-only question.
- **Manual file reading is the fallback, not the default.** Open files directly only to read/edit the specific lines a graphify query has already pointed you to, or for something genuinely outside the graph.
- **Keep the graph fresh.** After landing non-trivial code or doc changes, run `/graphify --update` so the graph reflects reality for the next agent.
- Pass this same rule to any subagent you dispatch to explore or analyze the code.

## 2. Use the superpowers skills

These are not optional. Match the skill to the work:

| Situation | Skill |
|---|---|
| New system / feature / behavior | `brainstorming` → then `writing-plans` |
| Writing any feature or bugfix | `test-driven-development` (write the test first) |
| A bug, test failure, or surprise | `systematic-debugging` |
| Independent parallel tasks | `using-git-worktrees` + `dispatching-parallel-agents` / `subagent-driven-development` |
| Before merging / finishing | `requesting-code-review`, then `receiving-code-review` |
| Before claiming anything "done" | `verification-before-completion` (evidence, not assertions) |

**Executing a written plan: ALWAYS use `subagent-driven-development`** (owner's standing preference — fresh subagent per task + two-stage review). Don't ask which execution mode; don't use inline `executing-plans` unless the owner explicitly overrides for a specific plan.

## 3. One owner per task

Work is tracked in **`docs/TASKS.md`** and the per-milestone files in `docs/milestones/`.

- **Claim** a task by setting yourself as its owner and status `in-progress` **before** starting.
- Don't pick up a task already `in-progress` under another owner — coordinate or pick another.
- Move tasks through: `todo → in-progress → review → done` (or `blocked`, with a note on what blocks it).

## 4. Decisions become ADRs

Any cross-cutting or architectural choice gets an Architecture Decision Record in `docs/adr/` (`NNNN-title.md`). Link the ADR from the tasks it affects. Don't silently re-decide something an ADR already settled — supersede it with a new ADR.

## 5. Specs precede netcode-bearing code

Every gameplay/netcode system gets a spec in `docs/specs/` (purpose, data, wire format, edge cases, test plan) **before** implementation. Use `brainstorming` to produce it.

## 6. Gates are hard

A milestone closes only when its **gate** passes with **recorded evidence** (bot-fleet run logs, telemetry numbers, or test output committed/linked). "It should work" is not a gate pass. Netcode-bearing gates are validated **with the bot fleet** at the stated player count.

## 7. Determinism & authority discipline

- The **server is authoritative**. Never trust client-reported state for anything that affects others; clients send *intent* (input), the server decides outcomes.
- Gameplay rules that run on both sides live in `shared/` so client prediction and server authority can't diverge. Don't fork rule logic into `client/` or `server/`.

## 8. Fleet gate host — game2 (local, full-time)

As of 2026-06-16 all dev + gate work runs on **game2** (Intel 14900KS, 32 threads, headless CachyOS), the full-time host. The user works here directly; a laptop only attaches to a **tmux session on game2** — the laptop runs nothing itself. Both the ≤48-bot smoke (`ci/`) and the 128-bot Docker fleet gate (`docker/`) run **locally on game2** — **no cross-host ssh**. The canonical working tree is **`/home/roland/projects/blockfire`** (a stale laptop-era copy at `/home/roland/blockfire` should be ignored).

**P-core / E-core pinning (HARD RULE):** the 14900KS is hybrid — **P-cores = logical CPUs 0–15** (fast, 5.9–6.2 GHz), **E-cores = 16–31** (4.5 GHz). `cpuset`/`taskset` pinning overrides the kernel's hybrid scheduler, so the single-threaded, clock-sensitive **server tick MUST be pinned to P-cores** (`SERVER_CPUS` ⊆ 0–15); pinning it onto an E-core gives a ~30% slower clock that reads as a phantom tick regression. Bots take the rest. Fleet example: `SERVER_CPUS=0,1,2,3 BOTS_CPUS=4-31 BOT_REPLICAS=16 BOT_COUNT=8 ./run-...-gate.sh`.

**Unraid (SENET, `ssh root@192.168.1.10`) is now PRODUCTION — do NOT run gates there.** If you ever must touch it, the old confinement rule still holds: stay strictly under **`/mnt/app/blockfire`** (treat as a chroot; it hosts live array/data shares) and pass that rule to any subagent.

## 9. Balance toward BattleBit; don't let conservative values block the gate

When choosing gameplay/balance values — weapon ammo/reserves, damage, fire rates, gadget counts, ranges, cooldowns, vehicle stats — **default to BattleBit's proven numbers** rather than inventing cautious placeholders. The project owner played BattleBit extensively and considers its balance well-tuned; it is our reference design. Match it as closely as the mechanic allows, and call out deliberate departures.

**Why this matters for gates:** overly conservative values can make a fleet gate fail to *exercise* a mechanic at all, which reads as a feature bug and burns expensive 128-bot iterations to diagnose. The canonical example (M5-P1): engineers were given a **single** RPG rocket per life, so the bot fleet could never land the concentrated anti-vehicle fire the vehicle-combat gate needed — several ~10-minute gate runs were spent before the real fix (BattleBit-style **3 rockets**, RPG used anti-vehicle-first) made it pass. Pick realistic values **up front**; when unsure, match BattleBit and note it in the spec. The silver lining is that gate failures surface real balance gaps — but it's cheaper to start from known-good numbers.

## 10. Prove mechanics deterministically; defer bot-AI *feel* to the visual client

A milestone gate must not depend on **emergent bot AI** to *exercise* a mechanic, and you must not tune bot-AI behaviour (pathing, target-finding, aim, tactics) "blind" off telemetry counters — that is a slow, low-signal loop (M5-P1 burned ~13 fleet runs / ~2 h chasing an RPG-kill that bots couldn't reliably stage; the underlying bugs would have been obvious in seconds on a rendered client).

- **Prove the mechanic deterministically** — a scripted scenario / unit-integration test that drives the exact chain (e.g. RPG blast → vehicle HP → destruction; engineer repair → HP restored) in seconds, with no AI involved. That test is the authoritative proof.
- **Use the bot fleet only for what it is uniquely good at** — scale, perf/tick budget, bandwidth, stability, match completion. Bots there generate *load*, not skilled play. Hard-gate those; mark AI-dependent combat counters **reported, not gated**.
- **Defer bot-AI tactical quality/feel to the M7 visual-client pass** — the owner will watch matches and diagnose against BattleBit experience far faster than blind number-tuning. Log AI-feel shortfalls as deferred-to-M7 items rather than blocking a milestone on them.

## 11. Land your work — commit, merge to master, and push when done (don't strand work on a worktree)

Worktrees and feature branches are **disposable and can be reclaimed by the harness mid-session**, taking their branch ref (and any un-merged commits) with them. On 2026-07-03 a completed spec+plan was lost this way — recovered only because the commits happened to survive as dangling objects. **Never leave completed work living only on a worktree/feature branch.**

The moment a coherent unit of work is finished and verified, land it:

1. **Commit** everything on your branch — no loose uncommitted changes.
2. **`git fetch origin`** and reconcile — another agent may have advanced `origin/master` (concurrent work is normal here; check the coordination notes in the relevant spec before merging).
3. **Merge to `master`** — `--no-ff` for a feature branch; a docs-only branch may fast-forward. A fast-forward is safe even when a concurrent agent has a dirty working tree in the main checkout, as long as the merge only touches files they haven't modified — verify with `git status --short` before and after.
4. **`git push origin master`.**

This applies to **every** deliverable, **including spec/plan-only branches** — a written spec or plan is completed work worth preserving. Pushing to `origin/master` on completion is owner-ratified (2026-06-27, **reaffirmed 2026-07-03** after the reclaimed-worktree loss). If you must stop with work genuinely incomplete, at minimum **commit and push the branch to `origin`** (`git push -u origin <branch>`) so nothing lives only in a reclaimable local worktree. When done inside a worktree, prefer the `finishing-a-development-branch` skill, which walks the merge/PR/cleanup decision — but do not `ExitWorktree`/end the session on unpushed completed work.

## 12. Current build priority — infantry + real maps + destruction; vehicles deferred

Owner-directed 2026-07-05: the near-term priority is, in order, **infantry combat → proper real maps → destruction**. Get those complete and playtested before starting anything else. **All remaining and future vehicle work is deferred to a dedicated post-core milestone** — see the "🚧 VEHICLES DEFERRED" banner at the top of `docs/TASKS.md`. The existing M5 land-vehicle sim stays on master (prediction-ready, gate-proven) but gets no further investment; do not pick up manual turret, client vehicle riding/exit polish, vehicle combat AI, or M10 air vehicles until the core is signed off. This does not require reverting any landed vehicle code — it's a *don't-start-new-vehicle-work* rule.

## 13. Push planning checkpoints immediately; allocate milestone numbers against `origin`

Milestone numbers (and shared identifiers — wire message ids, `Protocol.VERSION`, ADR numbers) are a **shared namespace across all agents**. They collide silently when an agent reserves one off a stale local `master` and doesn't publish it. Two hard rules:

1. **Before reserving a milestone number (or any shared id), `git fetch origin` and read the LIVE list on `origin/master`** — `docs/TASKS.md` + `docs/milestones/` — not your local checkout, which may be many commits behind. Pick the next free number from what `origin` actually shows.
2. **Push at every major checkpoint, not only when the whole feature is done.** Finishing **brainstorming (a committed spec)** or **planning (a committed plan)** is a checkpoint: immediately `git fetch origin` → reconcile → merge to `master` → `git push origin master`. A spec/plan that reserves a milestone number is exactly the thing other agents must be able to pull *before* they pick their own number. Don't sit on it locally while you move on to implementation.

**Cautionary tale (2026-07-11):** the stats/analytics spec was assigned **M19** off a stale local `master`; meanwhile `origin/master` had already shipped **M15–M17** (heightmap / bleed / reserve-ammo) and taken **M19** for Class Loadouts. Because the reservation was never pushed, nothing warned either side. Caught only by a manual re-grep; the milestone was renumbered to **M20** and the local branch rebased onto `origin/master`. Fetch-before-allocate and push-the-checkpoint would have prevented it. (This complements §11, which governs landing *completed* work — §13 says the spec/plan checkpoints count too.)

## Quick map

- **Start here for current state: `docs/STATUS.md`** (one-screen summary), then the milestone index in `docs/TASKS.md` (the authoritative board / plan of record).
- Board: `docs/TASKS.md` · Roadmap: `docs/milestones/` · Decisions: `docs/adr/` · Specs: `docs/specs/` · Ops: `docs/runbooks/` · Gate logs: `docs/gate-evidence/`
- **History (NOT current state): `docs/archive/`** — shipped-milestone plans, playtest session logs, and point-in-time reviews live here. Do **not** read them as the state of the code; they are provenance only.

## `backend/` — stats & analytics service (out of scope for game work)

`backend/` is the Python/FastAPI + PostgreSQL stats & analytics service
(design: `docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`).
It is **not part of the Godot game** and shares no runtime with `client/ server/
shared/ bots/`. When working on the game, do **not** scan, analyze, or modify
`backend/` — it only communicates with the game via the HTTP ingest contract.
Work there only when the task is explicitly the stats/analytics milestone.
