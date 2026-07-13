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
- The existing `Ladder` volume is **strictly vertical**, so we deploy a **vertical drop at the ledge** (owner choice) — zero climb-code change. Angled/diagonal ropes are deferred (they would need an angled-climb rework).

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
  3. the anchor building **collapses** (hooks the existing collapse → ladder-cleanup pass at `server_main.gd:2589`; a grapple ladder anchored to a collapsed `building_id` is dropped with the static ones).
- **Anyone climbs it** — it is a world ladder, identical to static map ladders once deployed (climb uses the unchanged `Ladder` helpers).

### Climb
- No new climb behaviour. Once the deployed volume is in the ladder query set, `Ladder.capture`/`should_engage`/`climb_step` handle engage/climb/dismount exactly as for static ladders (vertical climb at `LADDER_CLIMB_SPEED`, x,z locked, tops out onto the platform).

## Netcode / prediction

- **Server-authoritative deploy.** The client sends the fire action; the server validates range/anchor/charges/gate and owns the `deployed_ladders` list.
- The deployed ladder is **replicated to all clients** (`DEPLOYED_LADDER_LIST`), and each client **injects the received ladders into its local ladder-capture set** so:
  - the **owner predicts** their own climb (no round-trip stall — and since you fire from the ground and the line rises, the ~1-frame replication latency before you can climb is imperceptible),
  - **every** client renders the rope and can climb it.
- No prediction of the *deploy* itself (a gadget placement, like C4/breach/LMG-deploy — server-authoritative). The client may optimistically show a muzzle/throw FX; the authoritative ladder appears within a frame or two via the list.

## Wire protocol (`Protocol.VERSION 11 → 12`)

- **`GA_GRAPPLE_FIRE = 13`** — new sub-action on the existing gadget-action channel (payload: pos + facing dir), exactly like `GA_LMG_DEPLOY = 12`. **No new client→server message.**
- **`DEPLOYED_LADDER_LIST = 51`** — server → all clients. Authoritative deployed grapple ladders: `{ id, x, z, bottom_y, top_y }` per ladder (quantized like other position fields). Radius is a shared const, not sent. Drives rope render + client-side climb injection.
- **`SELF_STATE`** gains a trailing **`grapple_charges` u8** (append-only, `get_available_bytes`-guarded; decodes as "absent" on older clients). HUD readout only — same pattern as `stim_charges`.
- No new button bit (deploy is a fire action, not a held state — unlike `BTN_SHIELD`).
- `docs/specs/wire-protocol-registry.md` updated in the **same commit** (VERSION row, `GA_GRAPPLE_FIRE`, `DEPLOYED_LADDER_LIST=51`, SELF_STATE tail note; msg id 52 becomes the next free id).

## Client-only physics rope (cosmetic)

The **gameplay climb volume is a straight vertical line**; the **visual rope is a separate decorative mesh** that sways independently. It carries **no wire data and no determinism requirement** — each client renders it locally.

- **Procedural verlet/spring rope**, simulated per-frame on the client: a chain of ~8–12 segments **pinned at the top anchor** (and lightly tethered at the bottom), with gravity + damping + a low-frequency wind term so it flaps and settles. Rendered as a thin tube / `ImmediateMesh` along the segment points.
- **"Just deployed" swing** falls out of the sim for free: spawn the segments at the anchor and let them fall/settle, giving the rope the initial drop-and-flap.
- **Perf guard (128p):** only simulate ropes that are near + on-screen (≈ 30–40 m); beyond that draw a static straight line or skip. Piggybacks on existing deployed-entity distance relevance. Segment count and sim radius are tuning knobs.
- **Accepted caveat (on record):** because the rope is decoupled and cosmetic, it will not line up pixel-perfectly with the straight climb line — a climber's hands snap to the vertical line while the rope sways nearby. Standard for this effect; reads fine.

## New / changed code (mostly reuse)

- **New pure module `shared/sim/grapple.gd`** — anchor resolution + validation rules (range march result → `{ok, x, z, bottom_y, top_y, building_id}` or reject reason; range clamp; min-height; surface-hit classification). Side-effect-free, unit-tested like `riot_shield.gd`.
- **Server (`server_main.gd` + support seam)**:
  - `GA_GRAPPLE_FIRE` handler → `Grapple.resolve_anchor` → charge/gate checks → append to `deployed_ladders`.
  - `deployed_ladders` lifecycle: max-1-per-owner (evict old on redeploy), disconnect cleanup, collapse cleanup (extend the `2589` filter to drop ladders on the collapsed `building_id`). **No timer; the ladder survives owner death/respawn.**
  - Feed `deployed_ladders` into the ladder-capture query (concatenate with static `_sim.ladders`; keep them a **separate list** so only deployed ones replicate).
  - `DEPLOYED_LADDER_LIST` send; `grapple_charges` into `SELF_STATE`; resupply refill in `give_ammo`; charge reset on spawn.
- **Client (`client_main.gd` / `world_renderer.gd` / class-select / HUD)**:
  - Gadget input for the Grapple gadget → emit `GA_GRAPPLE_FIRE` (pos + aim dir), routed off `_loadout["gadget"]` like the other P2/P3 gadgets.
  - Decode `DEPLOYED_LADDER_LIST` → inject volumes into the client's ladder set (for own-climb prediction) + spawn/update/despawn the rope render nodes.
  - Client physics-rope renderer (verlet + perf guard) in `world_renderer`.
  - Un-grey `GADGET_GRAPPLE` in `ClassSelectPanel` (drop it from the "coming soon" set → add to `IMPLEMENTED_GADGETS`).
  - HUD grapple charge count (reads `grapple_charges`).
- **Bots (`bots/exercisers.gd`)**: a fraction of Assault bots deploy a grapple ladder near a building and climb it — a restrained, always-safe exerciser (cap 1/bot, cooldown, path/height sanity) that drives deploy → replicate → climb → charge economy → collapse cleanup under the fleet gate.

## Testing & gate

- **Deterministic unit tests** (`tests/*_test.gd`, extend `TestCase`):
  - `grapple_test.gd` — anchor resolution: valid surface within range → correct `{x,z,bottom_y,top_y}`; out-of-range reject; below-min-height reject; downed/vehicle/mounted gate; ground baseline (M15 sub-zero terrain safe).
  - Server-integration — deploy spends the (single) charge; a second deploy at 0 charges is rejected until restock; resupply refills the charge; spawn resets the charge to full; max-1 evicts the owner's old ladder on redeploy; the ladder **survives the owner's death/respawn**; owner disconnect removes it; anchor-building collapse removes it.
  - Climb-via-deployed-ladder — a deployed volume is captured and climbed by `Ladder` helpers (owner + a second pawn), confirming "anyone climbs".
  - Wire round-trip — `DEPLOYED_LADDER_LIST` encode/decode; `SELF_STATE` `grapple_charges` trailing byte append/absent.
- **Fleet gate:** 128-bot `conquest_town` on game2 (native encoder built), same bar as Riot Shield — **peak tick < 33.3 ms, 0 script errors, `grapples_deployed` > 0 and `grapple_climbs` > 0** (bot exerciser), nests/shield counters unregressed. Evidence committed to `docs/gate-evidence/`.
- Client rope is cosmetic (no gate assertion); validated by real-GPU screenshot on game2 (Xvfb, `tools/`) for owner sign-off.

## Deferrals (v1)

- **Angled / diagonal ropes** — vertical-only in v1 (climb system is vertical).
- **Rope final art tuning** — thickness / material / wind constants tuned on the real GPU during owner playtest (the sway itself ships in v1; only the polish is deferred).
- **Enemy "cut the rope"** interaction — a deployed ladder is destroyed only by its anchor collapsing / timer / owner, not by being shot. Follow-up if desired.
- **Sidearm/primary use while climbing** — inherits whatever the existing ladder-climb rules allow; no new grapple-specific combat state.

## Wire-registry delta (for the closing commit)

| id | name | dir | payload |
|----|------|-----|---------|
| 51 | `DEPLOYED_LADDER_LIST` | s→c (all) | deployed grapple ladders `{id, x, z, bottom_y, top_y}` |
| — | `GA_GRAPPLE_FIRE = 13` | c→s (gadget action) | pos + facing dir |
| — | `SELF_STATE` tail | s→c (owner) | `+grapple_charges u8` (append-only) |

`Protocol.VERSION` **11 → 12**. Next free msg id after this change: **52**.
