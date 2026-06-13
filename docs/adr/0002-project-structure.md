# ADR-0002: Project & export structure

- **Status:** Accepted
- **Date:** 2026-06-13
- **Context milestone:** M0

## Context

We ship three binaries — client, dedicated server, bot driver — that must share one simulation + protocol (`shared/`) so they can never drift. Two structures were considered:

1. **One Godot project** at the repo root; the three roles are selected at runtime (command-line flag / feature tag) and built via separate **export presets**. `shared/`, `client/`, `server/`, `bots/` are subdirectories of the single project.
2. **Three separate Godot projects** each referencing `shared/` as a shared addon/symlink.

## Decision

**Option 1: a single Godot project with role selection at runtime and per-role export presets.**

- One `project.godot` at the repo root.
- `shared/` holds the autoloads and classes used by all roles; `client/`, `server/`, `bots/` hold role-specific scenes/scripts.
- A small **bootstrap** (`shared/bootstrap.gd`, the main scene's entry) picks the role from CLI args:
  - `--server` → run dedicated server (expects `--headless`)
  - `--bots [--bot-count=N]` → run bot driver (expects `--headless`)
  - default → run client
- Server and bot builds export with the **headless / dedicated server** preset (no rendering); client exports normally.

## Rationale

- A single project means `shared/` is imported by all roles with **zero duplication or symlink/addon-sync friction** — directly serves the "rules can't drift" requirement.
- Godot's headless mode + feature tags + export presets are the engine-blessed way to produce a dedicated server from a shared codebase.
- Bot driver and server share the same headless setup, so one preset effort covers both.

## Consequences

- The client export must **exclude** server/bot-only scenes where it matters for build size (handled via export filters, not code structure).
- Role selection logic lives in one bootstrap path; keep it thin and well-tested (it's exercised by the M0 connect smoke test).
- CI builds the headless preset for the connect smoke test; the client preset is built less often (M7+).
