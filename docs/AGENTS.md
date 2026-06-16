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

## Quick map

- Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`
- Board: `docs/TASKS.md` · Roadmap: `docs/milestones/` · Decisions: `docs/adr/` · Specs: `docs/specs/` · Ops: `docs/runbooks/`
