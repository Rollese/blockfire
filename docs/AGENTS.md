# Working Agreement for Agents

This project is built largely by AI agents. Follow these rules so we stay coordinated and don't trample each other's work.

## 1. Read before you write — use graphify

Before modifying or analyzing any non-trivial part of the codebase, **use `graphify`** to build/query the knowledge graph of the code. Treat any question about architecture, file relationships, or "where does X happen" as a **graphify query first**, not a guess. If `graphify-out/` exists, query it before re-scanning.

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

## Quick map

- Plan of record: `~/.claude/plans/sorted-plotting-pebble.md`
- Board: `docs/TASKS.md` · Roadmap: `docs/milestones/` · Decisions: `docs/adr/` · Specs: `docs/specs/` · Ops: `docs/runbooks/`
