# M13 — Assault game mode (asymmetric attack/defend)

**Status:** planned (plan of record) · **Sequence:** **deferred until the core mechanics + rendered client are solid** (post-M7/M7.5/M8), before the beta-deferred M9/M10 · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md) · **Spec:** [`assault-mode`](../specs/assault-mode.md)

**Objective:** A second match mode beside Conquest — one team **Defends** all control points (no uncap), the other **Attacks** from an uncap. Defenders don't bleed until fully pushed off the map; attackers start with ~2× tickets and can win by tickets *or* by holding all CPs while no defender remains alive. Built as a **rules variant of the existing `ConquestState`** (M3) — not a new sim.

## Why deferred (not build-now)

Per the owner: develop this **after the core game mechanics and client are working well**. Assault is a content/mode addition, not a core-loop dependency — it reuses Conquest's capture/ticket machinery and the M12 FOB/spawn system. It is most valuable (and most tunable for feel) once the rendered client (M7), tactical bots (M7.5), and ops hardening (M8) exist. This milestone is the **plan of record** now; no TDD implementation plan is written until it is undeferred.

## Scope (when undeferred)

- **Mode setting** (`mode ∈ {CONQUEST, ASSAULT}`) at match start; default Conquest unchanged.
- **Asymmetric setup**: defenders own all CPs, no uncap; attackers own only an uncap. Map data gains a side-assignment block (reuses `points[]`/`bases[]`).
- **Ticket/bleed/win fork** in `shared/sim/conquest.gd`: defender bleed only while all CPs are attacker-held; recapture stops it; attacker ~2× tickets; attacker default-win (all CPs held + no living defender); time fail-safe favours a defender still holding ≥1 CP.
- **Spawning**: defenders have no uncap (CPs + FOB + squadmate only) — losing all CPs strands them; attackers spawn from the uncap + captured CPs + FOB + squadmate. Depends on the [M12 FOB](M12-squad-fob-class-refit.md) system.
- **Protocol**: `MATCH_STATE` + mode byte / side assignment.
- **Bot AI**: attacker bots push; defender bots hold + recapture; gate exerciser drives an all-CPs-taken window.

## Gate

A **128-bot Assault match** validated both ways, mechanics proven deterministically (AGENTS.md §10):

- An **all-CPs-taken window** occurs → **defender bleed** observed (telemetry); recapture stops it.
- **Attacker win** demonstrated — via the **default-win path** (all CPs held + last defender killed) and/or ticket drain.
- **Defender win** demonstrated in a separate run — attacker tickets drained, or the time fail-safe expires while defenders hold ≥1 CP.
- **Tick + bandwidth budget held** (mean tick < 33.3 ms at 128).
- Win-priority order, bleed-gating, and the default-win condition proven in unit/integration tests independent of emergent bot AI.

## Specs

- [`docs/specs/assault-mode.md`](../specs/assault-mode.md) — brainstormed; design approved 2026-06-18.

## Depends on

- **M3** Conquest capture/ticket machinery (done) — Assault is a fork of its stepping.
- **M12** squad FOB + spawn-source system — defenders' last-ditch spawn after losing CPs; attacker objective to clear it.
- **Core solid** (M7 client + M7.5 bots + M8 ops) before implementation begins.
