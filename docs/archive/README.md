# docs/archive — historical record (NOT current state)

Everything under `docs/archive/` is **kept for provenance only**. It is a
point-in-time record of *how* things were planned and playtested — **not** a
description of the code as it stands today.

> **Agents: do NOT read these as the current state of the code.** For current
> state start at [`../STATUS.md`](../STATUS.md), then the milestone index in
> [`../TASKS.md`](../TASKS.md). For a system's live design, read its spec in
> [`../specs/`](../specs). Use `graphify query "…"` for what the code actually does.

## What's here

| Folder | Contents |
|---|---|
| `plans/` | Implementation plans for milestones that have shipped. The blow-by-blow TDD task lists that produced the code. |
| `sessions/` | Playtest / handoff session logs (dated, point-in-time). |
| `reviews/` | Point-in-time codebase / architecture reviews. |
| `superpowers-plans/` · `superpowers-specs/` | Design + plan docs for shipped features (bleed/bandage, heightmap, lighting, native encoder, etc.). |
| `specs/` | Per-milestone spec snapshots for closed milestones, and design proposals superseded by an implemented spec. |

These files were moved here (via `git mv`, full content preserved) during the
2026-07-11 documentation compaction. The pre-compaction tree is also recoverable
from the git tag `docs-pre-compaction`.
