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

## 8. Unraid fleet host — stay confined

The 128-bot fleet gate runs on the unraid box **SENET** via `ssh root@192.168.1.10` (Docker + Compose installed). **HARD RULE for every agent:** when operating on unraid the working directory is **`/mnt/app/blockfire`** and you must **NEVER read or write any files outside it** — treat it as a chroot. unraid hosts live array/data shares; stray access risks unrelated data. Keep the repo, logs, and temp files all under `/mnt/app/blockfire`. Pass this rule explicitly to any subagent you dispatch to touch the fleet.

## Quick map

- Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`
- Board: `docs/TASKS.md` · Roadmap: `docs/milestones/` · Decisions: `docs/adr/` · Specs: `docs/specs/` · Ops: `docs/runbooks/`
