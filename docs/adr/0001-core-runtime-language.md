# ADR-0001: Core runtime language

- **Status:** Accepted
- **Date:** 2026-06-13
- **Context milestone:** M0

## Context

Blockfire needs custom authoritative netcode for up to 128 players at a 30 Hz tick. The shared simulation + (de)serialization runs on the server (authority), the client (prediction), and the bot driver (many bots/process). The hot path — snapshot encode/decode, interest management, entity sim — is performance-sensitive at 128p, and pure GDScript may not hold 30 Hz under full load.

Options considered:
1. **GDScript everywhere; escalate only hot paths to a GDExtension after profiling.**
2. GDScript (client UI/render) + a Rust GDExtension (`godot-rust/gdext`) core for `shared/` from the start.
3. C#/.NET everywhere.

## Decision

**Option 1: GDScript-first, escalate hot paths to GDExtension only if M1 profiling demands it.**

- Build `shared/`, the server, client prediction, and the bot driver in GDScript.
- Add **telemetry from day one** (M1) so we measure tick time and bandwidth rather than guess.
- The `shared/` core is structured so the hot path (snapshot serialization, interest grid, entity step) sits behind **narrow interfaces** that can be swapped for a GDExtension implementation (Rust via `gdext`, or C++) without touching callers.
- The M1 gate (128 pawns @ 30 Hz within budget) is the **decision point**: if GDScript misses the budget, open **ADR-0003** to escalate the identified hot path to GDExtension.

## Rationale

- **No premature toolchain dependency.** Rust is not installed in the dev environment; committing to a GDExtension core now adds build friction before we have anything to profile. (YAGNI.)
- **Fastest path to the M0/M1 gates**, which are what actually de-risk the project — and they produce the very measurements that would justify (or refute) going native.
- **Reversible.** The interface boundary keeps the escalation cheap and localized if profiling demands it.

## Consequences

- We accept the risk that GDScript may miss the 30 Hz/128p budget; mitigated by interface boundaries + the M1 gate as a forcing function.
- Any future native escalation must be recorded in a follow-up ADR and must not fork gameplay rules out of `shared/`.
- Contributors only need Godot 4.6 to build and run everything for M0–M3.
