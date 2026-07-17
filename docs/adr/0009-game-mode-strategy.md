# ADR-0009: Game-mode strategy — modes are rules-variants over one shared sim; new modes are content, not new games

- **Status:** Accepted
- **Date:** 2026-07-11
- **Context milestones:** M3 (Conquest), M13 (Assault), M9 (online services), plus any future mode work

## Context

The owner floated three additional game modes beyond the core BattleBit-style Conquest/Assault:

1. A **Fortnite-style Battle Royale** (large map, shrinking zone, ground loot, last-squad-standing, building).
2. An **RPG / shooter-MMO PvE mode** — squads of humans + AI running missions for XP and rarity-stat loot.
3. That PvE mode with **Tarkov-style extraction** — you only keep the loot if you get out.

Two real questions sat underneath the ideas: **is running many modes taxing on the engine/code**, and **should the different modes (especially the RPG/extraction one) be a separate game** rather than part of Blockfire? This ADR records the analysis and the resulting strategy so it does not get re-litigated each time morale dips and a pivot looks tempting.

This is explicitly also a **focus decision**. The owner has acknowledged that the pull toward "something new and exciting" is a morale response to the long foundation-first grind, not evidence that the plan is wrong. See [`memory: visible-progress-morale`] — the plan is sound; resist the pivot.

## Decision

### 1. New modes are **rules-variants over the one shared deterministic sim**, not new games

This is already the established, gated pattern and it is ratified as the general rule:

- Conquest ([M3](../milestones/M3-conquest-squads.md), done) and Assault ([M13](../milestones/M13-assault-mode.md), planned) are the **same sim** with a different win/ticket/spawn fork — Assault is "a rules variant of the existing `ConquestState` — not a new sim" ([ADR-0007](0007-battlebit-divergences.md) §3).
- The sim is a **custom kinematic, zero-Godot-physics, headless-testable core** shared by client/server/bots ([ADR-0002](0002-project-structure.md), [ADR-0005](0005-client-renderer.md)). Weapons, ballistics, destruction, movement, building, and the M7.5 bot-AI engine all live below the mode layer and are reusable by any mode.

**Consequence:** "many modes" is **not** a meaningful engine/code cost. The engine does not care how many rules-variants sit on top of the sim. The scarce resource is **focus and finishing**, not compute.

### 2. Mode cost is measured by **substrate**, not by combat

The expensive part of a mode is never the shooting — that is already built. Cost is driven by whether the mode needs a **new substrate underneath the sim**. Ranked:

| Mode | New substrate needed | Cost |
|---|---|---|
| **Battle Royale** | Shrinking-zone damage field, ground-loot spawns, no-respawn win fork — all on the *existing* sim + the netcode already proven at 128 bots | **Low** — a rules variant, like Assault |
| **Assault** (M13) | None (pure Conquest fork) | **Low** (already planned) |
| **Extraction / RPG-MMO** | Persistent backend (stash/inventory/XP), accounts, anti-cheat, loot/rarity/stat system, mission/AI-director content pipeline | **High** — this is M9-plus, not a feature |

### 3. Everything stays in **one project**; extraction's persistence layer is a *separable subsystem*, not a separate game

Starting a separate game throws away ~90% of what is built and gated — the shared sim, weapons, ballistics, destruction, netcode, and bot AI. [ADR-0002](0002-project-structure.md)'s single-Godot-project + role-selection design and the rules-variant mode pattern were **chosen precisely to host multiple modes cheaply**. Rebuilding that foundation for a "separate game" is the biggest available mistake.

The one nuance: the extraction/RPG **persistence backend** (accounts, stash, loot, XP) must be built as a **cleanly separable subsystem** — it is [M9](../milestones/M9-online-services.md)++ — so the RPG/loot/account machinery never entangles the deterministic LAN core.

### 4. Sequencing and identity guards

- **Do not start any new mode now.** The [M7](../milestones/M7-art-ux.md) rendered-client human-playtest gate is not yet passed — the *first* mode is not yet proven fun rendered. Adding modes before that is the classic indie trap and contradicts the project's foundation-first discipline.
- **When a mode is added, Battle Royale goes first.** It is the cheap, high-synergy variant that proves the rules-variant pattern a second time and de-risks extraction by exercising ground-loot and no-respawn flows.
- **Extraction / RPG is a post-1.0 track, gated behind M9.** It cannot precede the persistence backend it depends on.
- **RPG stats + rarity is a design-identity departure** from BattleBit's flat, skill-based, no-progression ethos (the standing balance rule, AGENTS.md §9). If pursued, it gets its **own ADR** ratifying the departure, in the style of [ADR-0007](0007-battlebit-divergences.md).

## Rationale

- The rules-variant architecture is evidenced, not assumed: Conquest is gated at 128 bots and Assault is specced as a fork of it. Extending that pattern is low-risk.
- The real risks of the RPG/extraction idea are **not** technical-combat risks: persistent loot value makes **anti-cheat existential** (LAN trust model dies — see [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md)), and MMO/extraction is a **live-service content-treadmill commitment** unlike BattleBit's "ship a solid sandbox" model. These are the honest costs to weigh, and they live entirely in the substrate, not the sim.
- Keeping everything in one repo preserves the shared-sim "rules can't drift" guarantee (ADR-0002) across all modes.

## Ratified mode roster (owner-directed 2026-07-16)

The release mode set is confirmed as **five rules-variants over the one shared sim**, all low-cost per the substrate analysis above:

1. **Conquest** (M3, done) — baseline.
2. **Assault** (M13, specced) — asymmetric attack/defend; pure Conquest fork.
3. **Team Deathmatch** (M23, planned) — kill-count win, no capture points; the cheapest variant (win-condition swap only).
4. **Gun Game** (M24, planned) — per-kill weapon-progression ladder; small new per-player state (current weapon tier), server-authoritative loadout override.
5. **Battle Royale** (M18, planned) — the largest (shrink-zone + ground-loot + parachute-glide substrate); sequenced last of the modes.

Sequencing when the mode wave starts (after the M7 rendered-client "is it fun rendered" gate, per §4): Assault → TDM → Gun Game → Battle Royale, cheapest-substrate first.

## Consequences

- Battle Royale becomes a recognized **future mode** (rules-variant), to be brainstormed/specced when the core is solid — the natural first mode after Conquest/Assault.
- **TDM (M23)** and **Gun Game (M24)** are added to the planned mode roster (owner-directed 2026-07-16); both are rules-variants requiring no new substrate — TDM is a win-condition swap, Gun Game adds a per-player weapon-tier that the existing loadout-apply path already supports.
- The extraction/RPG mode is recorded as a **post-1.0 track behind M9**, requiring its own identity ADR before implementation.
- This ADR is the canonical answer to "should we pivot / start a new game / add mode X" — point future sessions here rather than re-deriving it.
- No code, milestone, or gate changes result from this ADR directly; it is a strategy/roadmap decision. Reversible in principle by a later ADR, but each point above is an owner-ratified call.
