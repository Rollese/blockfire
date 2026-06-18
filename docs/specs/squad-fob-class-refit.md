# Spec: Squad FOB, Cooperative Construction & Class Refit

**Status:** approved (design) · **Date:** 2026-06-18 · **Milestone:** [M12](../milestones/M12-squad-fob-class-refit.md) · **Decision:** [ADR-0007](../adr/0007-battlebit-divergences.md)

Implements the §1 + §2 decisions of [ADR-0007](../adr/0007-battlebit-divergences.md):

1. **Class refit** — remove the Recon class, restrict the DMR to Assault (no sniper rifles), move the claymore to Engineer.
2. **Cooperative shovel construction** — replace M4's instant snap-to-grid placement with a **progressive, shovel-built** model: every class carries a **shovel**, placing a piece creates a *build site* that must be shovelled up to completion. Small pieces are solo-buildable; **large structures and the FOB require ≥2 squadmates shovelling together**.
3. **Squad-leader FOB** — a **destructible, cooperatively-built bunker** (placeholder model) that becomes a squad forward-spawn. Spawning is disabled while an enemy is in its vicinity; the bunker is destructible (M4 destruction) and hunted by enemy AI. Squadmate-rally spawn is retained as a fallback.

Server-authoritative; all rules live in `shared/` so client prediction and server authority can't diverge (AGENTS.md §5, §7). Bot-fleet-gated + deterministically proven (the M3/M4/M4.5 mould).

**Why now (before/with M7):** the M7 rendered client is building class-select + deploy/spawn UI and will need a shovel/build UI and a FOB world model. Landing this sim change first means M7 builds the 4-class roster, the shovel/construction UI, and the FOB deploy/spawn UI directly, instead of building Recon + squadmate-only-spawn + instant-build UI it would have to rip out.

> **Supersedes part of M4 (Building):** M4's **instant placement** model is replaced by progressive shovel construction (a *build site* that accrues progress). M4's grid/catalog/replication/collision and **all of M4 Phase-2 destruction** are reused unchanged — the FOB and all built structures are destroyed via the existing M4 destruction path. M4 building/destruction milestone + spec carry superseded notes.

## Design decisions (ratified — see ADR-0007)

| Decision | Choice | Rationale |
|---|---|---|
| Classes | **Assault, Medic, Engineer, Support** (Recon removed) | Drops the passive long-range-camping class; four clear roles. |
| Sniper rifles | **None, ever; DMR is the only precision option** | Semi-auto DMR already exists and is semi-auto; M5.5 already rejected sniper sway. Ratified rule. |
| DMR access | **Assault-only** (server-validated at loadout) | Folds the marksman role into the frontline rifleman; one validation rule (mirrors RPG=Engineer-only). |
| Claymore/mine | **Engineer Gadget A, pick-one vs C4** | Keeps the gadget in the sandbox without breaking the two-slot-per-class convention; Engineer's Gadget B (vehicle repair) untouched. |
| Build tool | **Universal shovel, all classes** | One progressive build method for everything; encourages squad cooperation. Replaces M4 instant placement. |
| Cooperation gate | **Min builders scale by structure size** | Small piece = 1 builder (solo ok, faster with help); large structure / FOB = **≥2 simultaneous** shovellers to progress. Forces real cooperation on the big builds without removing solo cover. |
| Resource cost | **Labor only (shovel time + builder count); no supply economy** | Keeps M4's deliberate "no resource economy"; the cooperation gate is the builder-count, not collected supplies. |
| FOB structure | **Destructible bunker, cooperatively built** (≥2), placeholder model | Squad-game-style FOB, not a drop-and-go beacon. A real objective the enemy hunts. |
| FOB counterplay | **Proximity disables spawning AND destructible** | Layered: suppress its vicinity to stop the spawn flood; destroy the bunker to remove it — explosives/weapons (M4 destruction) or, with no explosives, slowly **shovel-dismantle** it. |
| Squadmate-rally spawn | **Retained as a fallback** | Still spawn on an alive squadmate when no usable FOB; FOB is primary, not exclusive. |

---

## Phasing

M12 is split into three independently-gated phases (the project's phase-gate norm, cf. M4.5):

- **M12-P1 — Class refit.** Recon removal, DMR Assault-only, claymore→Engineer. Small, self-contained, no new systems — lands first.
- **M12-P2 — Cooperative shovel construction.** Universal shovel; build sites replace instant placement; min-builders-by-size; repair; decay. Supersedes the M4 build model. Built on M4 grid/catalog/collision + M4 destruction.
- **M12-P3 — Squad-leader FOB.** Leader places a FOB build site; squad shovels it (≥2); destructible bunker becomes a spawn source with proximity-disable; spawn-selection integration; squadmate-rally fallback.

Each phase holds the tick + bandwidth budget at 128 bots and keeps Conquest reaching a winner.

---

## A. Class & weapon refit — M12-P1 (`shared/sim/loadout.gd`, `shared/sim/weapon.gd`)

### Classes (`loadout.gd`)
- Remove `RECON` from the class enum. Classes become `ASSAULT=0, MEDIC=1, ENGINEER=2, SUPPORT=3`.
- `random_class()` → `randi() % 4`; `random_class_no_engineer()` pool becomes `[ASSAULT, MEDIC, SUPPORT]` (the Engineer human-exclusion for the RPG-primary variant is unchanged — out of scope).
- `weapon_for(cls)`: Recon→DMR mapping removed. Defaults unchanged for the four classes (Engineer→SMG; Assault/Medic/Support→AR). The DMR is now an **opt-in loadout choice for Assault** (see below), not a class default.

### DMR restriction (`loadout.gd` `can_equip`)
- Extend `can_equip(cls, weapon_id)`: `Weapon.DMR` is equippable **only when `cls == ASSAULT`** (alongside the existing `Weapon.RPG` ⇒ Engineer-only rule). All other primaries remain unrestricted. Loadout-time validation only.
- No bolt-action/sniper weapon id is added to `weapon.gd`. The `AR / SMG / DMR / RPG` set is unchanged; the DMR stays semi-auto (M5.5 `DMR = SEMI`).

### Claymore → Engineer (`loadout.gd`)
- Engineer's Gadget A becomes a **pick-one between C4 and claymore/mine** chosen at the deploy screen (loadout field). The Engineer loadout carries `gadget_a ∈ {GADGET_C4, GADGET_MINE}`; server validates the value is one of the two. Other classes keep their fixed gadget (`MEDIC→HEAL`, `SUPPORT→AMMO`, `ASSAULT→NONE`).
- The mine/claymore gadget data and server tick (`_step_mines`, proximity trigger, `MAX_MINES_PER_PLAYER`) are unchanged from M4.5 — only its **owning class** changes.

---

## B. Cooperative shovel construction — M12-P2 (`shared/sim/structure.gd` ext, new `shared/sim/build_site.gd`)

Replaces M4's instant placement. **Placing a piece creates a build site, not a finished structure**; the structure exists (with collision/cover/HP) only once shovelled to completion.

### Shovel (universal tool)
- Every class carries a **shovel** (a tool slot, like the knife — always available, no loadout cost). Holding the shovel "use" action while aiming at a build site / friendly structure within `SHOVEL_RANGE` contributes build (or repair) work.
- Shovelling is a **held input action** (an input/gadget-channel bit); the server computes each builder's contribution per tick from eligible builders near a site (no per-shovel message).

### Build sites (`build_site.gd`)
- `BuildSiteRecord := {id, owner, team, cell, yaw, piece_id, build_progress, min_builders}` (extends the M4 `StructureRecord` with `build_progress` + `min_builders`, or a parallel "under-construction" flag on the record).
- **Placement:** `Msg.BUILD_REQUEST` (M4) now creates a build site at `build_progress = 0` (snap-to-grid, bounds/occupancy validation unchanged from M4). The site is a **low/no-collision ghost** — it provides **no cover until complete** (v1 simplification). Per-player site cap + cooldown carried over from M4.
- **Progress (server, per tick):** for each active site, count `eligible = friendly players within SHOVEL_RANGE, facing the site, holding shovel-use`. If `eligible >= site.min_builders`:
  `build_progress += SHOVEL_RATE_PER_BUILDER * min(eligible, MAX_BUILDERS_PER_SITE) * dt`.
  Otherwise no progress (a large/FOB site with only 1 shoveller does **not** advance). On `build_progress >= piece.build_cost`: the site **completes** → becomes a normal M4 structure (full collision/cover, `health = piece.health`, destructible via M4 Phase-2).
  - `min_builders`: **small pieces = 1** (solo ok, faster with help up to `MAX_BUILDERS_PER_SITE`); **large structures = 2**; **FOB = 2** (P3).
- **Repair:** shovelling a *completed* friendly structure below max HP restores `SHOVEL_REPAIR_RATE * dt` up to `piece.health`. Repair is **solo-allowed** (min_builders ignored for repair).
- **Enemy shovel-dismantle:** shovelling an **enemy** structure/site *removes* it — the no-explosives route to take down cover when you have no frags/RPG/C4. Available to **any** class (not inventory-gated). On a build site (under construction), it reduces `build_progress` toward 0 at `SHOVEL_DISMANTLE_RATE * builders * dt` (site removed at 0); on a *completed* structure, it applies the same as HP damage toward 0 (removed at 0 via the M4 destruction removal path — bucket-delta, attached-C4 cleanup, etc.). **Solo-allowed** (min_builders is a *construction* gate only), and **scales with the number of enemy diggers** up to `MAX_BUILDERS_PER_SITE`; deliberately **much slower than explosives**, so it is a fallback, not the primary demolition tool. Applies to the FOB bunker too (§C) — slow against its high HP, but possible for an enemy with only a shovel.
- **Decay:** a site with no shovelling for `BUILD_SITE_DECAY_TICKS` and `build_progress < build_cost` decays (freed), so abandoned ghosts don't accumulate.
- **Catalog:** `pieces/fortifications.json` gains `build_cost` and `min_builders` per piece; add at least one **large** piece type (for the ≥2 path) plus the FOB (P3). Small pieces (sandbag/wall) get `min_builders=1`, modest `build_cost`.

### Replication
- `STRUCTURE_DELTA`/`STRUCTURE_BASELINE` (M4) extended with `build_progress` (quantized) + an `under_construction` bit. Active-site progress is sent on a **low cadence** (on meaningful change, or a slow per-site tick), **not** the per-tick snapshot. Completion/destruction are events. Bounded by the per-player/site cap.

---

## C. Squad-leader FOB — M12-P3 (`shared/sim/fob.gd` NEW, build-site + spawn path)

The FOB is a **large build site → destructible bunker** that becomes a squad forward-spawn. It is an instance of the P2 construction system (a special large piece) plus spawn semantics.

### Lifecycle
- `FobRecord := {squad_id, team, structure_id, pos}` referencing the underlying structure/build-site. **At most one FOB (built or under-construction) per squad.**
- **Placement (site):** squad **leader only** (first member, per M3 leader rule). `Msg.PLACE_FOB` requests a FOB build site at the leader's position. Server validates: requester is the alive squad leader; valid ground, in bounds; **not inside an enemy-owned capture radius** or the enemy home base; no existing squad FOB (placing a new one removes the old). The FOB site is a **large piece (`min_builders = 2`)** → the squad must shovel it up.
- **Build:** squadmates shovel the FOB site per §B (≥2 simultaneous shovellers to progress). On completion it becomes the **bunker** (placeholder model): high HP (`FOB_HEALTH`), full collision/cover.
- **Persistence:** the built FOB **persists through the leader's death** (it's a structure, not tied to the leader's pawn). Removed when: the leader places a new FOB, it is destroyed (HP→0), or the squad disbands with no successor leader.
- **Destruction:** the bunker takes damage via the **M4 Phase-2 destruction path** (weapons/explosives); at 0 HP it is removed and the squad loses the spawn. Friendly players may **shovel-repair** it (solo-allowed); enemy players may **shovel-dismantle** it (§B) — the no-explosives route, slow against its high HP but viable for an enemy carrying only a shovel.

### Spawn gating
The FOB is a valid spawn source **iff**: it is **completed** (built, not still a site), **not destroyed**, and **no enemy pawn is alive within `FOB_VICINITY_RADIUS`** (planar XZ; reuses the interest grid). Proximity-disable is temporary (re-enables when enemies leave/die); destruction is permanent (must rebuild).

### Replication
- FOB replicated to its **own team**: `{squad_id, structure_id, under_construction bit, enabled bit}` (enabled derived server-side from enemy proximity). Built/under-construction/destroyed states ride the structure delta (the bunker is a structure). Enemies see the bunker as a normal structure (it is one — so enemy AI naturally targets it), but do **not** get a "this is squad N's FOB" label in v1.

---

## D. Spawn selection (`server/server_main.gd` `_select_spawn`, extends M3 §E)

**Valid sources** for a client on team `T`, squad `S`:
- the team's **home base** (always valid);
- every **capture point owned by `T`**;
- the **squad's FOB**, *if completed, not destroyed, and spawn-enabled* (no enemy within `FOB_VICINITY_RADIUS`);
- every **alive squadmate** (same `squad_id`, alive, not self) — **fallback**, retained per ADR-0007.

Choice policy unchanged from M3 (nearest valid source to the client's objective; humans pick in M7). Position jitter (`SPAWN_JITTER`) unchanged. First spawn / no FOB / no alive squadmate ⇒ home base, as before.

## E. Wire protocol changes (`shared/net/protocol.gd`)

- New `Msg.PLACE_FOB` / `Msg.REMOVE_FOB` (client→server, CONTROL): leader places/removes the squad FOB site.
- **Shovel-use** input bit (held action) carried on the existing INPUT/gadget channel — no new per-action message; server computes build/repair contribution per tick.
- `Msg.BUILD_REQUEST` semantics change: creates a build site (M12-P2) instead of a finished piece.
- `STRUCTURE_DELTA`/`STRUCTURE_BASELINE` extended: `build_progress` (quantized) + `under_construction` bit; low-cadence on active sites.
- FOB entity replication (own team): `{squad_id, structure_id, under_construction, enabled}` — low-frequency reliable on change.
- No per-tick SNAPSHOT field changes.

> **M11 coordination:** `shared/net/protocol.gd` and the structure store / `STRUCTURE_DELTA` are also evolved by the in-flight **M11 destructible-buildings** track. M12-P2/P3 build on the same structure machinery, so they must be **sequenced after M11 merges or closely coordinated with the M11 agent** to avoid protocol-enum/codec and structure-record conflicts. (M12-P1 — the class refit — is independent of M11 and can land first.)

## F. Bot AI (`bots/bot_driver.gd`)

- Drop Recon from bot class rolls (4 classes); Engineers roll `gadget_a` (C4 or claymore) so both are exercised.
- **Shovel/build:** bots place + shovel small cover at objectives (replacing M4's instant build). **Squad bots converge to build the FOB cooperatively** — a leader bot places a FOB site near its objective and ≥2 squadmates shovel it to completion; squadmate bots then prefer the FOB spawn when enabled.
- **Enemy AI targets the FOB:** because the built FOB is a normal destructible structure, the existing structure-aware combat/destruction behaviour applies; add a light preference for shooting/RPG-ing a known enemy FOB bunker near the front. **An enemy bot with no explosives available falls back to shovel-dismantling** an enemy structure/FOB it is adjacent to and blocked by.
- **Deterministic exerciser (AGENTS.md §10):** a scripted **squad-build drill** (a squad of bots places a FOB site and ≥2 shovel it to completion, then spawn on it; an enemy element then destroys it) guarantees the gate exercises cooperative construction + FOB spawn + proximity-disable + destruction every match, independent of emergent AI.

## G. Constants (initial values; gate-tuned — default toward Squad/BattleBit feel)

| Const | Value | Meaning |
|---|---|---|
| `SHOVEL_RANGE` | 3.0 m | max range to shovel a site/structure |
| `SHOVEL_RATE_PER_BUILDER` | tune | build progress / s per active builder |
| `MAX_BUILDERS_PER_SITE` | 4 | builder count cap for rate scaling |
| `BUILD_SITE_DECAY_TICKS` | 900 (30 s) | abandoned, incomplete site decays |
| `SHOVEL_REPAIR_RATE` | tune | HP / s restored to a completed friendly structure |
| `SHOVEL_DISMANTLE_RATE` | tune (≪ explosive DPS) | progress/HP / s removed from an enemy structure per digger; deliberately slow |
| `MIN_BUILDERS_SMALL` | 1 | sandbag/wall solo-buildable |
| `MIN_BUILDERS_LARGE` | 2 | large structures need ≥2 simultaneous |
| `FOB_MIN_BUILDERS` | 2 | FOB bunker needs ≥2 simultaneous |
| `FOB_HEALTH` | tune (high) | bunker HP (M4 destruction) |
| `FOB_VICINITY_RADIUS` | 40.0 m | enemy within → FOB spawning disabled |
| `FOB_BUILD_COST` | tune (high) | shovel work to complete the bunker |
| `MAX_FOBS_PER_SQUAD` | 1 | active FOBs (built or site) per squad |
| `FOB_MIN_DIST_FROM_ENEMY_CP` | = point `radius` | cannot place inside an enemy-owned capture radius |

## H. Budgets

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz), unchanged budget. New per-tick work: per active build site, O(builders within `SHOVEL_RANGE`) via the interest grid — bounded by the per-player site cap and `MAX_BUILDERS_PER_SITE`. FOB enemy-proximity check is O(enemies near the FOB) at spawn-selection time. No new per-tick stream. Profile to confirm no regression on `snap` (the dominant M3 cost) — the construction tick is expected to fold into the cheap respawn/gadget phase like M4.5's gadget ticks.
- **Bandwidth:** `STRUCTURE_DELTA` gains `build_progress` on a low cadence for active sites only; FOB entity replication ≤ a few bytes per squad on change — negligible vs the snapshot stream. No per-tick structure stream (M4's event-based model preserved).

## I. Testing

**Unit (`TestCase`):**
- `loadout`: 4-class enum; `can_equip` allows DMR only for Assault, RPG only for Engineer, rejects DMR for non-Assault; Engineer `gadget_a` accepts only `{C4, MINE}`.
- `build_site`: placement creates a site at 0 progress (no cover); a small site (min 1) advances with 1 builder; a large/FOB site (min 2) does **not** advance with 1 builder, **does** with 2; rate scales with builders up to `MAX_BUILDERS_PER_SITE`; completion flips to a full structure with collision + HP; repair restores HP solo; abandoned site decays.
- `shovel-dismantle`: an enemy shovelling a friendly-of-other-team build site reduces `build_progress` (removed at 0); shovelling a completed enemy structure reduces HP (removed at 0 via the M4 path); dismantle is solo-allowed and scales with diggers; a *friendly* shovel never damages own-team structures (repairs/builds instead); dismantle rate is ≪ explosive damage.
- `fob`: leader-only placement; rejected inside enemy CP/base; one-per-squad replace; built FOB persists through leader death; removed on destruction / disband; enemy-proximity enable/disable boundary (just inside vs just outside `FOB_VICINITY_RADIUS`); a destroyed FOB is not a spawn source.
- `spawn selection`: FOB offered only when completed + enabled + alive; squadmate fallback when no FOB; never returns an enemy/neutral point; home-base fallback when nothing else valid.
- `protocol`: `PLACE_FOB`/`REMOVE_FOB`, `STRUCTURE_DELTA` with `build_progress`/`under_construction`, FOB entity round-trip.

**Integration / gate:** see [M12 gate](../milestones/M12-squad-fob-class-refit.md#gate) — per phase: P1 loadout restrictions; P2 cooperative construction (small solo-built, large built only with ≥2, all under budget); P3 a 128-bot match where a squad builds a FOB cooperatively, spawns on it, has it proximity-disabled by enemies, and has it destroyed — with the tick/bandwidth budget held and a winner declared.

## J. Out of scope (explicit)

- **Supply / build-point economy** — building costs labor (shovel time) + the builder-count gate, not collected supplies (preserves M4's no-resource-economy decision).
- **Partial-build cover** — a site gives no cover until complete in v1 (revisit if playtest wants progressive cover/HP).
- **Destructible-FOB intel label / "spotted FOB"** for enemies — the bunker is a visible structure but not labelled as a squad FOB to the enemy in v1.
- Client shovel/build UI, build-site ghost rendering, and the FOB world model/VFX — **M7** (this spec replicates the data the UI needs; M7 renders it; placeholder model until art).
- Re-tuning the Engineer human-exclusion (pre-existing M4.5 quirk).
- Any Assault-mode interaction (M13) — defined there.
