# Spec: Squad FOB & Class Refit (Recon removal, DMR/claymore reassignment, leader FOB spawn)

**Status:** approved (design) · **Date:** 2026-06-18 · **Milestone:** [M12](../milestones/M12-squad-fob-class-refit.md) · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md)

Implements the §1 + §2 decisions of [ADR-0007](../adr/0007-battlebit-divergences.md): remove the Recon class, restrict the DMR to Assault, move the claymore to Engineer, and replace the M3 "spawn on any alive squadmate" primary with a **squad-leader-built FOB** (squadmate-rally retained as a fallback). Server-authoritative; all rules live in `shared/` so client prediction and server authority can't diverge (AGENTS.md §5, §7). Bot-fleet-gated like its predecessors (M3/M4.5).

**Why now (before/with M7):** the M7 rendered client is building class-select + deploy/spawn UI. Landing this sim change first means M7 builds the 4-class roster and FOB deploy/spawn UI directly, instead of building Recon + squadmate-only-spawn UI it would have to rip out.

## Design decisions (ratified — see ADR-0007)

| Decision | Choice | Rationale |
|---|---|---|
| Classes | **Assault, Medic, Engineer, Support** (Recon removed) | Drops the passive long-range-camping class; four clear roles. |
| Sniper rifles | **None, ever; DMR is the only precision option** | Semi-auto DMR already exists and is semi-auto; M5.5 already rejected sniper sway. Ratified rule. |
| DMR access | **Assault-only** (server-validated at loadout) | Folds the marksman role into the frontline rifleman; one validation rule (mirrors RPG=Engineer-only). |
| Claymore/mine | **Engineer Gadget A, pick-one vs C4** | Keeps the gadget in the sandbox without breaking the two-slot-per-class convention; Engineer's Gadget B (vehicle repair) untouched. |
| Primary forward spawn | **Squad-leader FOB** (one per squad) | Leader-controlled, enemy-suppressible forward spawn — counterplay vs M3's free squad teleport. |
| FOB under enemy pressure | **Spawning disabled while an enemy is in the vicinity; FOB persists** | Forgiving, low-grief: pressure shuts off the spawn flood without forcing a rebuild cycle. |
| Squadmate-rally spawn | **Retained as a fallback** | Still spawn on an alive squadmate when no FOB is up/usable; FOB is primary, not exclusive. |

## A. Class & weapon refit (`shared/sim/loadout.gd`, `shared/sim/weapon.gd`)

### Classes (`loadout.gd`)
- Remove `RECON` from the class enum. Classes become `ASSAULT=0, MEDIC=1, ENGINEER=2, SUPPORT=3`.
- `random_class()` → `randi() % 4`; `random_class_no_engineer()` pool becomes `[ASSAULT, MEDIC, SUPPORT]` (the Engineer human-exclusion for the RPG-primary variant is unchanged — out of scope).
- `weapon_for(cls)`: Recon→DMR mapping removed. Defaults unchanged for the four classes (Engineer→SMG; Assault/Medic/Support→AR). The DMR is now an **opt-in loadout choice for Assault** (see below), not a class default.

### DMR restriction (`loadout.gd` `can_equip`)
- Extend `can_equip(cls, weapon_id)`: `Weapon.DMR` is equippable **only when `cls == ASSAULT`** (alongside the existing `Weapon.RPG` ⇒ Engineer-only rule). All other primaries remain unrestricted. Loadout-time validation only.
- No bolt-action/sniper weapon id is added to `weapon.gd`. The `AR / SMG / DMR / RPG` set is unchanged; the DMR stays semi-auto (M5.5 `DMR = SEMI`).

### Claymore → Engineer (`loadout.gd`, `data/gadgets.json` unchanged in shape)
- Engineer's Gadget A becomes a **pick-one between C4 and claymore/mine** chosen at the deploy screen (loadout field), not a fixed gadget.
- `gadget_for(cls)` is replaced (for Engineer) by a loadout-driven selection: the Engineer loadout carries a `gadget_a ∈ {GADGET_C4, GADGET_MINE}` field; server validates the value is one of the two. Other classes keep their fixed gadget (`MEDIC→HEAL`, `SUPPORT→AMMO`, `ASSAULT→NONE`).
- The mine/claymore gadget data and server tick (`_step_mines`, proximity trigger, `MAX_MINES_PER_PLAYER`) are unchanged from M4.5 — only its **owning class** changes.

## B. FOB — Forward Operating Base (`shared/sim/fob.gd` NEW, spawn path)

A squad-leader-placed forward spawn anchor. Pure rules + record struct in `shared/sim/`; server owns placement, lifecycle, and the enemy-proximity gate.

### Record & lifecycle
- `FobRecord := {squad_id, team, pos, tick_placed}`. Server tracks **at most one FOB per (team, squad_id)**.
- **Placement (build):** squad **leader only** (first member of the squad, per M3 leader rule). A new `Msg.PLACE_FOB` intent (CONTROL channel) requests placement at the leader's current position. Server validates:
  - requester is alive and is their squad's leader;
  - position is on valid ground, inside world bounds, **not inside any enemy-owned capture-point radius** and not inside the enemy home base;
  - a `BUILD_FOB_TICKS` channel completes (leader stationary; cancels on death/move beyond a small tolerance).
  On success, replace the squad's existing FOB (if any) with the new record.
- **Removal:** an explicit `Msg.REMOVE_FOB` from the leader, or automatic removal when a new one is placed. The FOB **persists through leader death** (it is a placed beacon, not tied to the leader's pawn). On squad disband / leader slot emptying with no successor, the FOB is removed.
- **No proximity-destroy:** enemies cannot destroy the FOB by standing near it (that only disables spawning — see below). v1 has no FOB HP/hit-resolution (kept simple; revisit only if playtest demands a destructible FOB).

### Enemy-proximity spawn gate
- The FOB is **spawn-enabled** iff **no enemy pawn is alive within `FOB_VICINITY_RADIUS`** (planar XZ) of `pos`. Computed server-side each spawn-selection (reuses the per-tick interest grid where available — O(enemies in cell)).
- When disabled, the FOB simply is not offered as a spawn source for that selection; it stays on the map and re-enables automatically once enemies leave/die.

### Replication
- FOB replicated to its **own team** as a small entity `{squad_id, pos}` (enabled-state is derived client-side from known enemy positions, or sent as one bit — implementer's call; ≤ a few bytes per squad, low frequency). Enemies do **not** see friendly FOBs in v1 (no intel leak; revisit if a "spotted FOB" feature is wanted). Reuses the existing reliable CONTROL/entity replication pattern; no new per-tick stream.

## C. Spawn selection (`server/server_main.gd` `_select_spawn`, extends M3 §E)

Replace M3's squad-spawn source set. **Valid sources** for a client on team `T`, squad `S`:
- the team's **home base** (always valid);
- every **capture point owned by `T`**;
- the **squad's FOB**, *if present and spawn-enabled* (no enemy within `FOB_VICINITY_RADIUS`);
- every **alive squadmate** (same `squad_id`, alive, not self) — **fallback**, retained per ADR-0007.

Choice policy unchanged from M3 (nearest valid source to the client's objective; humans pick in M7). Position jitter (`SPAWN_JITTER`) unchanged. First spawn / all-points-neutral with no FOB and no alive squadmate ⇒ home base, as before.

## D. Wire protocol changes (`shared/net/protocol.gd`)

- New `Msg.PLACE_FOB` (client→server, CONTROL): request FOB placement (position taken from server-side pawn pos; body may be empty or carry a confirm token).
- New `Msg.REMOVE_FOB` (client→server, CONTROL): leader removes own FOB.
- FOB entity replication (server→team): `{squad_id u8, pos (3×f32 or quantized), enabled u8(bit)}` per active FOB, low-frequency reliable on change (not per-tick). Negligible bandwidth (≤8 squads/team).
- No INPUT-channel changes; no change to the per-tick SNAPSHOT field set.

> **M11 coordination:** `shared/net/protocol.gd` is also edited by the in-flight M11 destructible-buildings track (`STRUCTURE_DELTA`). Adding the FOB message ids must be **sequenced after M11 merges or coordinated with the M11 agent** to avoid a protocol-enum/codec conflict (same gate the art-pipeline spec observes).

## E. Bot AI (`bots/bot_driver.gd`)

- Drop Recon from bot class rolls (uses `random_class()` → 4 classes).
- Engineers roll a `gadget_a` (C4 or claymore) so both are exercised in a match.
- **Squad-leader bots place a FOB**: when a leader bot is alive, past a hold-down area near its objective and no FOB exists (or the current one is far from the front), issue `PLACE_FOB`. Squadmate bots prefer the FOB spawn source when enabled. This guarantees the gate exercises FOB placement + FOB-spawn + enemy-proximity-disable deterministically (a scripted FOB drill, per AGENTS.md §10, if organic placement proves match-outcome-dependent).

## F. Constants (initial values; gate-tuned — default toward BattleBit/Squad feel)

| Const | Value | Meaning |
|---|---|---|
| `FOB_VICINITY_RADIUS` | 40.0 m | enemy within → FOB spawning disabled |
| `BUILD_FOB_TICKS` | 60 (2 s) | leader build channel |
| `MAX_FOBS_PER_SQUAD` | 1 | active FOBs per squad |
| `FOB_MIN_DIST_FROM_ENEMY_CP` | = point `radius` | cannot place inside an enemy-owned capture radius |

## G. Budgets

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz), unchanged budget. New per-tick/selection work: FOB enemy-proximity check is O(enemies near the FOB) via the interest grid, run at spawn-selection time (not every tick for every pawn). FOB placement/removal are low-frequency CONTROL events. No new per-tick stream. Profile to confirm no regression on `snap` (the dominant M3 cost).
- **Bandwidth:** FOB entity replication ≤ a few bytes per squad, on-change reliable — negligible vs the snapshot stream.

## H. Testing

**Unit (headless `TestCase`):**
- `loadout`: 4-class enum; `can_equip` allows DMR only for Assault, RPG only for Engineer, rejects DMR for non-Assault; Engineer `gadget_a` accepts only `{C4, MINE}`; `random_class`/`random_class_no_engineer` ranges.
- `fob`: placement validation (leader-only, alive, valid ground, rejected inside enemy CP/base); one-per-squad replace; persists through leader death; removed on disband; enemy-proximity enable/disable boundary (just inside vs just outside `FOB_VICINITY_RADIUS`).
- `spawn selection`: FOB offered only when present + enabled; squadmate fallback still works when no FOB; never returns an enemy/neutral point; home-base fallback when nothing else valid.
- `protocol`: `PLACE_FOB` / `REMOVE_FOB` + FOB entity round-trip.

**Integration / gate:** see [M12 gate](../milestones/M12-squad-fob-class-refit.md#gate) — a 128-bot Conquest match where FOBs are placed, used as a spawn source, and disabled by enemy proximity (telemetry counters), with no Recon class present, DMR Assault-only, and the tick/bandwidth budget held + a winner declared.

## I. Out of scope (explicit)

- **Destructible FOB** (HP/hit-resolution) — v1 uses proximity-disable only. Revisit if playtest wants enemies to destroy it.
- **Enemy visibility of FOBs / "spotted FOB"** intel — friendly-only in v1.
- Client deploy-screen FOB-build UI and FOB world model/VFX — **M7** (this spec replicates the data the UI needs; M7 renders it).
- Re-tuning the Engineer human-exclusion (pre-existing M4.5 quirk).
- Any Assault-mode interaction (M13) — defined there.
