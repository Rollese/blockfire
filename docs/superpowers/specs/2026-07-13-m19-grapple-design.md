# M19 — Grappling Hook (Assault gadget) — Design

_Status: **Approved** (owner-ratified 2026-07-13). Design-of-record for the last remaining M19 gadget._
_Milestone: M19 Class Select & Loadouts (tracked in [`docs/TASKS.md`](../../TASKS.md) + spec [`specs/class-select-loadout.md`](../../specs/class-select-loadout.md) §D "Heavy new — GRAPPLE"). Precedent feature: Riot Shield (`shared/sim/riot_shield.gd`, M19 P5)._

## One-liner

The Assault **Grappling Hook** gadget deploys a **vertical, climbable rope-ladder** up a building face, roof edge, or terrain ledge that **anyone — friend or foe — can climb** (BattleBit-faithful: the hook is not a reel; it is a deployable climb line). It reuses the existing `Ladder` climb system and the deployed-entity replication pattern (`EMPLACEMENT_LIST`/`FOB_LIST`), so the genuinely new sim/wire surface is small. A **client-only physics rope** sways/flaps over the (invisible, straight) gameplay climb line.

## Why this shape

- BattleBit's grappling hook creates a climbable wire that persists in the world for anyone to use — it does **not** reel the firer in. The owner confirmed we match this.
- This codebase already has everything a climbable line needs:
  - `shared/sim/ladder.gd` — pure `capture`/`should_engage`/`climb_step` on a vertical `{bottom, top, radius}` volume (bottom/top share x,z; climbing locks to that line).
  - `_sim.ladders` is **already a mutable runtime array** — collapse code adds/removes ladders live (`server_main.gd:2589` keeps a filtered `kept_ladders`). A deployed grapple ladder is therefore "append a volume to the runtime set" + replicate it.
  - Deployed-entity replication is an established pattern (`FOB_LIST=40`, `EMPLACEMENT_LIST=50`).
- The deployed rope is **always a vertical drop at the ledge** — it reuses the existing strictly-vertical `Ladder` volume with zero climb-code change. (Angled/diagonal anchoring is out of scope entirely — not a concept in this feature.)

## Gameplay rules

### Deploy
- Player selects the Grapple gadget (`GADGET_GRAPPLE`, already an Assault option in `Loadout.gadget_options`), aims at a surface, and fires. Firing is an **instant throw action** — no held state, no fire-lock.
- Server marches the aim ray (`StructureStore.march` for structures + `Terrain`/platform query) up to **`GRAPPLE_MAX_RANGE` (≈ 22 m)**. On a valid surface hit it derives an **anchor**:
  - `top_y` = the hit surface's top y (roof-deck / ledge level, so a climber tops out onto the platform exactly like the existing roof ladders).
  - `x, z` = the anchor's horizontal position (the climb line).
  - `bottom_y` = `max(Terrain.height_at(x,z), Ladder.platform_floor(...))` directly below the anchor — the real ground/platform baseline (M15-safe, mirrors existing ground logic).
- **Rejected (no charge spent)** when: no surface within range, OR `top_y - bottom_y < GRAPPLE_MIN_HEIGHT (≈ 2.5 m)` (no stubby ground ropes), OR the deployer is downed / in a vehicle / mounted on an emplacement (anti-exploit gate, mirrors `pawn.shield_up`'s server-side derivation).
- Radius = the shared `Ladder.LADDER_CAPTURE_RADIUS` const (not sent on the wire).

### Economy & lifetime
- **`GRAPPLE_CHARGES` = 1** charge — **single-use per life**. Reset to full (1) on spawn; a deploy spends the charge; once spent, the player **cannot deploy again until they restock from support** (ammo box / `ServerSupport.give_ammo`, same seam as reserve ammo & stim charges — refills up to the cap of 1). This makes the grapple a resource the player coordinates with their support class for.
- **Max one active ladder per owner.** Redeploying (only possible with a charge, i.e. after a restock or a fresh spawn) **moves it** — removes the owner's previous ladder and places the new one.
- **No lifespan timer** — a deployed ladder is a **persistent map feature** and survives the owner's death/respawn. It is removed only on the **first** of:
  1. owner redeploys (their previous ladder is replaced),
  2. owner **disconnects** / leaves the server (housekeeping — the record would otherwise be un-ownable),
  3. the anchor building **collapses** (hooks the existing collapse → ladder-cleanup pass at `server_main.gd:2589`; a grapple ladder anchored to a collapsed `building_id` is dropped with the static ones),
  4. **any nearby player cuts it** once it is cuttable (see *Cutting the rope*).
- **Anyone climbs it** — it is a world ladder, identical to static map ladders once deployed (climb uses the unchanged `Ladder` helpers).

### Cutting the rope
Player-driven removal that replaces a fixed timer with a **guaranteed-uptime-then-contestable** model.
- A deployed ladder is **uncuttable for its first `GRAPPLE_CUT_ARM_TICKS` (≈ 30 s @ 30 Hz)** — the deployer gets 30 s of guaranteed use. After that it becomes **cuttable**.
- Once cuttable, **any player of any team** within `GRAPPLE_CUT_RADIUS` (≈ 1.5 m of the climb line, any height) can cut it via a dedicated **interact action** (instant, no channel). This is deliberately open to *all* players (owner, teammates, enemies) per owner direction — it is a contest/clear mechanic, not an enemy-only one.
- Cutting **removes the ladder immediately for everyone** (server drops it from `deployed_ladders` and the next `DEPLOYED_LADDER_LIST` reflects the removal). **Anyone climbing it at that moment is dropped** — the climb volume vanishes, so the existing gravity/`Fall` logic takes over (fall damage applies emergently; noted, not special-cased).
- The cut does **not** refund the owner's charge (the owner must still restock to redeploy).
- Server validates every cut: ladder exists, `age ≥ GRAPPLE_CUT_ARM_TICKS`, requester within `GRAPPLE_CUT_RADIUS`, requester alive/not-downed. Invalid cuts are ignored (anti-exploit; no client-trusted removal).

### Climb
- No new climb behaviour. Once the deployed volume is in the ladder query set, `Ladder.capture`/`should_engage`/`climb_step` handle engage/climb/dismount exactly as for static ladders (vertical climb at `LADDER_CLIMB_SPEED`, x,z locked, tops out onto the platform).
- **No firing at all while climbing — ever** — a grappled rope behaves exactly like any other ladder: while the `climbing` flag is set, fire input is fully suppressed (server + client-predicted, off the existing climb-state flag). This is a hard rule, not a tunable; it inherits/relies on the standard ladder no-fire behaviour and the implementation must enforce it (closing the gap if static ladders don't already).

## Netcode / prediction

- **Server-authoritative deploy.** The client sends the fire action; the server validates range/anchor/charges/gate and owns the `deployed_ladders` list.
- The deployed ladder is **replicated to all clients** (`DEPLOYED_LADDER_LIST`), and each client **injects the received ladders into its local ladder-capture set** so:
  - the **owner predicts** their own climb (no round-trip stall — and since you fire from the ground and the line rises, the ~1-frame replication latency before you can climb is imperceptible),
  - **every** client renders the rope and can climb it.
- No prediction of the *deploy* itself (a gadget placement, like C4/breach/LMG-deploy — server-authoritative). The client may optimistically show a muzzle/throw FX; the authoritative ladder appears within a frame or two via the list.

## Wire protocol (`Protocol.VERSION 11 → 12`)

- **`GA_GRAPPLE_FIRE = 13`** — new sub-action on the existing gadget-action channel (payload: pos + facing dir), exactly like `GA_LMG_DEPLOY = 12`. **No new client→server message.**
- **`DEPLOYED_LADDER_LIST = 51`** — server → all clients. Authoritative deployed grapple ladders: `{ id, x, z, bottom_y, top_y, cuttable }` per ladder (positions quantized like other fields; `cuttable` is a bit/u8 the server flips once the ladder's age ≥ `GRAPPLE_CUT_ARM_TICKS`). Radius is a shared const, not sent. Drives rope render, client-side climb injection, and the "cut" prompt gating.
- **`CUT_LADDER = 52`** — client → server. A player requests to cut a deployed ladder by id. Server validates existence + `age ≥ GRAPPLE_CUT_ARM_TICKS` + requester within `GRAPPLE_CUT_RADIUS` + requester alive; on success removes the ladder (next `DEPLOYED_LADDER_LIST` reflects it). Open to all teams. Zero-trust: invalid requests are ignored.
- **`SELF_STATE`** gains a trailing **`grapple_charges` u8** (append-only, `get_available_bytes`-guarded; decodes as "absent" on older clients). HUD readout only — same pattern as `stim_charges`.
- No new button bit (deploy and cut are discrete actions, not held states — unlike `BTN_SHIELD`).
- `docs/specs/wire-protocol-registry.md` updated in the **same commit** (VERSION row, `GA_GRAPPLE_FIRE`, `DEPLOYED_LADDER_LIST=51` incl. `cuttable`, `CUT_LADDER=52`, SELF_STATE tail note; msg id 53 becomes the next free id).

## Client-only physics rope (cosmetic)

The **gameplay climb volume is a straight vertical line**; the **visual rope is a separate decorative mesh** that sways independently. It carries **no wire data and no determinism requirement** — each client renders it locally.

- **Procedural verlet/spring rope**, simulated per-frame on the client: a chain of ~8–12 segments **pinned at the top anchor** (and lightly tethered at the bottom), with gravity + damping + a low-frequency wind term so it flaps and settles. Rendered as a thin tube / `ImmediateMesh` along the segment points.
- **"Just deployed" swing** falls out of the sim for free: spawn the segments at the anchor and let them fall/settle, giving the rope the initial drop-and-flap.
- **Perf guard (128p):** only simulate ropes that are near + on-screen (≈ 30–40 m); beyond that draw a static straight line or skip. Piggybacks on existing deployed-entity distance relevance. Segment count and sim radius are tuning knobs.
- **Accepted caveat (on record):** because the rope is decoupled and cosmetic, it will not line up pixel-perfectly with the straight climb line — a climber's hands snap to the vertical line while the rope sways nearby. Standard for this effect; reads fine.

## New / changed code (mostly reuse)

- **New pure module `shared/sim/grapple.gd`** — anchor resolution + validation rules (range march result → `{ok, x, z, bottom_y, top_y, building_id}` or reject reason; range clamp; min-height; surface-hit classification) plus the pure cut-eligibility helper (`can_cut(age_ticks, dist)` → arm-delay + radius test). Side-effect-free, unit-tested like `riot_shield.gd`.
- **Server (`server_main.gd` + support seam)**:
  - `GA_GRAPPLE_FIRE` handler → `Grapple.resolve_anchor` → charge/gate checks → append to `deployed_ladders`.
  - `deployed_ladders` lifecycle: max-1-per-owner (evict old on redeploy), disconnect cleanup, collapse cleanup (extend the `2589` filter to drop ladders on the collapsed `building_id`). **No timer; the ladder survives owner death/respawn.**
  - Feed `deployed_ladders` into the ladder-capture query (concatenate with static `_sim.ladders`; keep them a **separate list** so only deployed ones replicate). Each record carries `deploy_tick` (for the cut-arm age) and `owner`/`building_id` (for cleanup).
  - Per-tick: flip each ladder's `cuttable` once `tick - deploy_tick ≥ GRAPPLE_CUT_ARM_TICKS`.
  - `CUT_LADDER` handler → validate (exists, cuttable, requester within `GRAPPLE_CUT_RADIUS`, alive) → remove from `deployed_ladders`.
  - `DEPLOYED_LADDER_LIST` send (incl. `cuttable`); `grapple_charges` into `SELF_STATE`; resupply refill in `give_ammo`; charge reset on spawn.
- **Client (`client_main.gd` / `world_renderer.gd` / class-select / HUD)**:
  - Gadget input for the Grapple gadget → emit `GA_GRAPPLE_FIRE` (pos + aim dir), routed off `_loadout["gadget"]` like the other P2/P3 gadgets.
  - Decode `DEPLOYED_LADDER_LIST` → inject volumes into the client's ladder set (for own-climb prediction) + spawn/update/despawn the rope render nodes.
  - Cut interaction: when within `GRAPPLE_CUT_RADIUS` of a `cuttable` ladder, show a "cut rope" prompt (reuses the bandage/interact-prompt pattern) and emit `CUT_LADDER` (id) on the interact keypress.
  - Client physics-rope renderer (verlet + perf guard) in `world_renderer`.
  - Un-grey `GADGET_GRAPPLE` in `ClassSelectPanel` (drop it from the "coming soon" set → add to `IMPLEMENTED_GADGETS`).
  - HUD grapple charge count (reads `grapple_charges`).
- **Bots (`bots/exercisers.gd`)**: a fraction of Assault bots deploy a grapple ladder near a building and climb it; a further restrained slice **cuts** a nearby aged enemy ladder — a always-safe exerciser (cap 1/bot, cooldown, path/height sanity) that drives deploy → replicate → climb → charge economy → cut → collapse cleanup under the fleet gate.

## Testing & gate

- **Deterministic unit tests** (`tests/*_test.gd`, extend `TestCase`):
  - `grapple_test.gd` — anchor resolution: valid surface within range → correct `{x,z,bottom_y,top_y}`; out-of-range reject; below-min-height reject; downed/vehicle/mounted gate; ground baseline (M15 sub-zero terrain safe). Cut eligibility: `can_cut` false before arm delay / outside radius, true after arm delay within radius.
  - Server-integration — deploy spends the (single) charge; a second deploy at 0 charges is rejected until restock; resupply refills the charge; spawn resets the charge to full; max-1 evicts the owner's old ladder on redeploy; the ladder **survives the owner's death/respawn**; owner disconnect removes it; anchor-building collapse removes it.
  - Cut — a `CUT_LADDER` before the arm delay is ignored; after the arm delay from within radius it removes the ladder for everyone; from outside radius it is ignored; the cut does not refund the owner's charge; a pawn climbing the cut ladder is released to gravity/`Fall`.
  - Climb-via-deployed-ladder — a deployed volume is captured and climbed by `Ladder` helpers (owner + a second pawn), confirming "anyone climbs"; **fire input is suppressed while the `climbing` flag is set** (no-fire rule).
  - Wire round-trip — `DEPLOYED_LADDER_LIST` (incl. `cuttable`) encode/decode; `CUT_LADDER` encode/decode; `SELF_STATE` `grapple_charges` trailing byte append/absent.
- **Fleet gate:** 128-bot `conquest_town` on game2 (native encoder built), same bar as Riot Shield — **peak tick < 33.3 ms, 0 script errors, `grapples_deployed` > 0, `grapple_climbs` > 0, `grapple_cuts` > 0** (bot exerciser), nests/shield counters unregressed. Evidence committed to `docs/gate-evidence/`.
- Client rope is cosmetic (no gate assertion); validated by real-GPU screenshot on game2 (Xvfb, `tools/`) for owner sign-off.

## Deferrals (v1)

- **Rope final art tuning** — thickness / material / wind constants tuned on the real GPU during owner playtest (the sway itself ships in v1; only the polish is deferred).

_(Out of scope entirely — not deferrals, not concepts here: angled/diagonal ropes; firing while climbing.)_

## Wire-registry delta (for the closing commit)

| id | name | dir | payload |
|----|------|-----|---------|
| 51 | `DEPLOYED_LADDER_LIST` | s→c (all) | deployed grapple ladders `{id, x, z, bottom_y, top_y, cuttable}` |
| 52 | `CUT_LADDER` | c→s | ladder id to cut (server-validated: cuttable + in radius + alive) |
| — | `GA_GRAPPLE_FIRE = 13` | c→s (gadget action) | pos + facing dir |
| — | `SELF_STATE` tail | s→c (owner) | `+grapple_charges u8` (append-only) |

`Protocol.VERSION` **11 → 12**. Next free msg id after this change: **53**.
