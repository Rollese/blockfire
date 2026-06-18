# ADR-0007: Deliberate divergences from BattleBit defaults (Recon/sniper removal, squad-leader FOB spawn, Assault mode, beta-defer of online/air)

- **Status:** Accepted
- **Date:** 2026-06-18
- **Context milestones:** M3 (squads/spawning), M4.5 (class identity), M12 (squad FOB & class refit), M13 (Assault mode), M9 (online services), M10 (air vehicles)

## Context

The project's standing balance rule is **"default to BattleBit's proven numbers and mechanics; call out deliberate departures"** (AGENTS.md §9). The owner has played BattleBit extensively and treats it as the reference design. This ADR records four owner-directed departures decided on 2026-06-18 — each is a place where we judge a different choice better than the BattleBit default, and §9 requires departures to be explicit.

These touch already-DONE, gated milestones (M3 spawning, M4.5 class identity), so they are not doc-only edits — they schedule fresh, gated implementation work (M12) and a new mode (M13).

## Decision

### 1. No Recon class; no sniper rifles; DMR is the long-range option (Assault-only)

- The **Recon class is removed**. Classes become **Assault, Medic, Engineer, Support** (was five incl. Recon).
- **No bolt-action / scoped sniper rifle exists or will be added.** The only long-range precision weapon is the **semi-automatic DMR** (already present and semi-auto; M5.5 already rejected sniper breath-hold/sway). This is ratified as a permanent design rule.
- The **DMR is restricted to the Assault class** (server-validated at loadout, same pattern as RPG=Engineer-only). Assault chooses AR *or* DMR; other classes keep their existing weapons.
- Recon's **claymore/mine** gadget moves to the **Engineer**, as a deploy-screen **pick-one with C4** in Engineer's Gadget A slot (Gadget B, vehicle repair, unchanged).

*Why:* the owner wants to avoid the passive, long-range-camping playstyle that a dedicated sniper/recon class encourages, while keeping a capable marksman option (DMR) folded into the frontline rifleman. Concentrating the DMR on Assault keeps a clear class identity and a single loadout-validation rule.

### 2. Squad-leader FOB (cooperatively built, destructible) + universal shovel construction

- **Universal shovel construction.** Every class carries a **shovel**, and player building becomes **progressive**: placing a piece creates a *build site* that must be shovelled to completion (replacing M4's instant placement). The cooperation requirement **scales by structure size** — small pieces (sandbag/wall) are solo-buildable (faster with help); **large structures and the FOB require ≥2 squadmates shovelling simultaneously** to progress. Labor only — no supply/resource economy (preserves M4's decision).
- **Squad-leader FOB.** The squad's forward spawn becomes a **destructible, cooperatively-built bunker** (placeholder model): the leader places a FOB build site (one per squad), the squad shovels it up (≥2 builders), and once complete it is a high-HP structure that becomes the squad spawn.
- **Layered counterplay.** Spawning is **disabled while an enemy is within the FOB's vicinity radius** (the FOB persists), and the bunker is **destructible** — via the existing M4 destruction path (weapons/explosives) or, for a player with no explosives, by slowly **shovel-dismantling** it (any class can dig down enemy structures; deliberately much slower than explosives). Enemy AI hunts it as a normal structure. Suppress to disable; destroy to remove.
- **Spawn-on-alive-squadmate is retained as a fallback** alongside home base + owned points; the FOB is the primary, leader-controlled forward option.

*Why:* M3 ratified "spawn on any alive squadmate," which lets a whole squad teleport to any pushed member with no counterplay. The owner wants **more squad cooperation** than BattleBit's drop-and-go recon beacon: a leader-placed bunker the squad must *build together* and the enemy can *suppress or destroy* — closer to the game **Squad's** FOB model. This **supersedes the M3 squad-spawn decision** and **part of the M4 building model** (instant placement → progressive shovel construction); M4 destruction and the grid/catalog/replication machinery are reused unchanged. M3 and M4 docs carry superseded notes.

### 3. New game mode: Assault (asymmetric attack/defend)

A second mode beside Conquest: **Defenders** start owning all control points with **no uncap**; **Attackers** own only an uncap. Both can win on tickets, but **defenders do not bleed until all CPs are attacker-held**, and **attackers start with ~2× the defenders' tickets**. CPs are capturable in **any order** and are **recapturable**. **Attackers also win by default** by holding all CPs while no living defender remains (with no uncap, defenders then have nowhere to respawn).

*Why:* the owner wants an asymmetric attack/defend experience on top of symmetric Conquest. See [Assault mode spec](../specs/assault-mode.md) / [M13](../milestones/M13-assault-mode.md). **Scheduled after the core mechanics + rendered client are solid** (post-M7/M7.5/M8) — a plan of record now, implemented later.

### 4. Online services (M9) and air vehicles (M10) deferred to a beta / post-1.0 phase

**M9 and M10 are deferred out of the core sequence** and are **not considered until every other milestone is finished**. M10 was already "deferred last"; this formalizes M9 alongside it as the beta/post-1.0 content.

*Why:* the core deliverable is a complete, playable LAN game (the M7 rendered client + the gated sim systems). Persistent online backend/matchmaking/anti-cheat (M9) and air vehicles (M10) are large tracks that depend on a finished, playtested client and add no value until the core game is solid.

## Consequences

- **M12 (squad FOB, cooperative construction & class refit)** is scheduled **near-term, before/alongside the in-progress M7 client**, so M7 builds the 4-class select, the shovel/build UI, and the FOB deploy/spawn UI rather than building Recon / instant-build / squadmate-only-spawn UI it would later rip out. It is phased: **P1** class refit · **P2** universal shovel construction (supersedes M4 instant placement) · **P3** the FOB bunker + spawn. Spec: [`squad-fob-class-refit`](../specs/squad-fob-class-refit.md).
- **M13 (Assault mode)** is plan-of-record now; implementation is gated behind a solid core (post-M7/M7.5/M8). Spec: [`assault-mode`](../specs/assault-mode.md).
- **M3**, **M4 (building)**, and **M4.5** milestone docs gain superseded-decision notes pointing here (squad spawn → FOB; instant placement → progressive shovel construction; Recon class removed / claymore reassigned). M4 destruction is reused unchanged.
- The **TASKS.md milestone index** re-buckets M9 + M10 under a deferred beta/post-1.0 heading and adds M12/M13.
- These are sim-layer / roadmap decisions; the server tick + bandwidth budgets and the server-authority discipline (AGENTS.md §7) are unchanged. New gates (M12, eventually M13) are bot-fleet-validated like their predecessors.
- Reversible in principle (a later ADR may supersede), but each is an owner design call, not a constraint we expect to revisit.
