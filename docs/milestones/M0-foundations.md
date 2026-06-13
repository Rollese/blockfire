# M0 — Foundations & Decisions

**Status:** done ✅ (gate passed 2026-06-13)

**Objective:** Stand up the repo, docs system, and the three Godot projects wired to a shared module, and prove a client and a bot can connect to a dedicated server over our own message layer.

## Tasks

- [x] Repo scaffold + `.gitignore` + git init
- [x] Docs system: `README`, `docs/AGENTS.md`, `docs/TASKS.md`, milestone files
- [x] **ADR-0001** core runtime language
- [x] **ADR-0002** project / export structure
- [x] `shared/` skeleton: net message layer (`shared/net/net_host.gd`, `protocol.gd`) + sim loop interface (`shared/sim/sim_loop.gd`)
- [x] `client/`, `server/`, `bots/` roles in a single Godot 4.6 project referencing `shared/`
- [x] Custom ENet message layer: server listens, client connects + handshake, bot connects
- [x] Headless connect smoke test (`ci/connect_smoke_test.sh`)
- [x] Docker + CI stubs, `docs/runbooks/running-locally.md`

## Gate

Empty **client connects to empty server** via the custom message layer (handshake completes, server acknowledges peer), and the **bot driver connects 1 bot** the same way. All headless-verifiable.

## Evidence (gate passed)

- **Command:** `ci/connect_smoke_test.sh` (Godot 4.6.3, headless, port 27115) → `SMOKE TEST: PASS`, exit 0.
- **Server log:** `welcomed peer 1 ('smoke-client') — 1 peers`, then `welcomed peer 2 ('bot-0') — 2 peers`.
- **Client log:** `WELCOME — id=1, server tick=30Hz`.
- **Bot log:** `bot 0 connected (id 2) — 1/1 connected`.
- **Date / owner:** 2026-06-13 / claude.

## Notes / decisions

- Environment verified: Godot 4.6.3, git present. **Docker and Rust not installed** — treated as prerequisites documented in runbooks, not M0 blockers.
- ADR-0001 leans GDScript-first (escalate hot paths to GDExtension only if M1 profiling demands it) to avoid a premature toolchain dependency.
