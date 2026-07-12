# M19 P4 — LMG Nest (manned MG emplacement)

Status: design (2026-07-12)
Milestone: M19 Class Select & Loadouts, Phase 4 (final gadget)
Track: M19 (Class Loadouts) — independent of M18 (BR) / M20 (stats)

## Summary

The **LMG Nest** is Support's third and final gadget: a **deployable, manned,
destructible machine-gun emplacement**. A Support player places it at their aim point,
**mounts** it, and fires a **high-capacity suppressive MG on a limited traverse arc**
until it overheats or is destroyed. It is BattleBit-faithful in feel: a static gun that
trades mobility for sustained suppression and a slice of hard cover, with an exposed
gunner who can be shot or blasted off it.

`Loadout.GADGET_LMG_NEST := 12` and `SUPPORT: [GADGET_AMMO, GADGET_RIOT_SHIELD,
GADGET_LMG_NEST]` are already reserved. This phase makes the gadget real end-to-end and
flips it into `IMPLEMENTED_GADGETS` so the P3 class-select screen stops greying it.

## Two ratified decisions (owner, 2026-07-12)

1. **Scope = full first-person manning this phase.** Not just the headless sim + fleet
   gate — the complete client experience ships too: mounting snaps the camera to the gun,
   a **traverse-clamped aiming reticle**, an **overheat + ammo HUD**, and dismount. This
   gets a client screenshot sign-off pass like P3.
2. **Entity model = dedicated `Emplacement`, vehicle code untouched.** We do **not**
   instantiate `Vehicle` or reuse `VEHICLE_ACTION`/`VehicleState`. We build a standalone
   `Emplacement` sim entity, its own mount action, its own replication list, and its own
   client render. We **copy the proven vehicle-gunner *patterns*** (seat occupancy, turret
   aim-mirror, mounted-gun fire, whole-entity HP) into that dedicated class, but the parked
   vehicle system stays parked and separate.

## Non-goals / deferrals

- No drivable vehicles, no `vehicle_spawns` — the parked vehicle direction is unchanged.
- **Enemy stealing** a nest — v1 is friendly-mount-only (owner's team). Deferred.
- **Repairing** a damaged nest (engineer repair-kit) — deferred; a damaged nest stays damaged.
- Multiple nests per player — v1 is **one active nest per owner** (placing a second removes the first).
- Bipod/deployable-cover buffs to the player's own LMG — out of scope; the nest is a distinct MG.

## Architecture

The nest sits at the intersection of two existing systems, one for each half of its life:

- **Place it** like a deployable gadget (model on the C4/bag/FOB path):
  `GADGET_ACTION` sub-action for deploy, server-side placement validation via
  `BuildSiteStore.validate_place` (ground / bounds / range), a server-owned
  `_lmg_nests` store, tick + cleanup like the other gadget stores.
- **Man + fire it** by copying the vehicle-gunner mechanics into a dedicated class:
  single seat, occupant slaved to the seat, gunner yaw feeds a **clamped** turret yaw,
  a mounted-gun fire tick with heat/overheat, whole-entity HP + destruction that ejects
  the gunner.

### New / touched components

| Unit | File | Responsibility |
|---|---|---|
| `Emplacement` entity | `shared/sim/emplacement.gd` (new, `class_name`) | Pure-ish state + static rules: `make()`, traverse clamp, `can_mount`, seat/muzzle geometry, heat step, `hit()`/`mark_destroyed()`. No I/O. |
| Catalog def | `shared/sim/gadget.gd` + `data/gadgets.json` | `KIND_LMG_NEST := 9`, `"lmgnest"` def (hp, arc, mg stats, heat). |
| Loadout flags | `shared/sim/loadout.gd` | Add `GADGET_LMG_NEST` to `IMPLEMENTED_GADGETS`; add to Support `bot_gadget` rotation. |
| Wire | `shared/net/protocol.gd` | `VERSION 9 → 10`. New `GA_LMG_DEPLOY`, and a dedicated `EMPLACEMENT_ACTION` msg (`EA_MOUNT`/`EA_DISMOUNT`, nest id) + `EMPLACEMENT_LIST` (server→clients, rebuilt each tick). Owner-only heat/ammo/overheat appended to `SELF_STATE`. |
| Server lifecycle | `server/server_main.gd` (+ maybe `server/emplacement.gd` extract) | `_lmg_nests` store; deploy / mount / dismount handlers; per-tick occupant-slave + turret-mirror + fire + heat; HP damage hooks (bullet/explosion/RPG/sledge); destruction → eject; `EMPLACEMENT_LIST` broadcast; reset cleanup. |
| Client render | `client/world_renderer.gd`, `client/art/*` | Render the nest mesh (tripod/sandbag MG), pivot the barrel to `turret_yaw`, damage-state visual, remove on destroy. Pose a **remote** gunner crouched at the gun. |
| Client FP manning | `client/client_main.gd`, `client/input_controller.gd`, `client/hud/*` | Mount: camera to sight, movement→clamped traverse+pitch, fire→MG, reticle, heat + ammo HUD, dismount key. |
| Class-select | `client/menus/class_select_panel.gd` | No code change — flipping `IMPLEMENTED_GADGETS` un-greys it (already data-driven). |
| Bots | `bots/exercisers.gd`, `bots/roles.gd`, `bots/ai/behaviors/*` | `NEST` cohort of Support bots: deploy → man → arc-sweep fire → dismount when flanked/destroyed. Guarantees the fleet gate exercises it. |
| Tests | `tests/emplacement_*_test.gd` (new) | Deterministic proofs (see Testing). |

### `Emplacement` entity (sim)

Immobile, single-gunner. No physics `step()` (unlike Vehicle). Fields: `id` (disjoint id
space, `EMPLACEMENT_BASE` well clear of pawn ids 1..128 and vehicle `ID_BASE`), `owner_id`,
`team`, `pos` (ground-snapped deploy point), `facing_yaw` (deploy facing = **arc centre**),
`turret_yaw` / `pitch` (current aim), `occupant` (pawn id, 0 = unmanned), `hp` / `max_hp`,
`heat` / `overheated_until` (tick), `ammo` (belt), `reloading_until`, `alive`.

Static rules (pure, unit-tested without a server):
- `clamp_traverse(yaw, facing_yaw, half_arc) -> yaw` — wrap-aware clamp of aim into
  `[facing_yaw - half_arc, facing_yaw + half_arc]`. Pitch clamped to `[-pitch_lo, pitch_hi]`.
- `can_mount(e, p, dist, range) -> bool` — nest alive & unmanned, pawn alive/not-downed/
  not-in-a-nest, **same team** (v1), within `MOUNT_RANGE`.
- `seat_world()` / `muzzle()` — seat + muzzle offsets from `pos` rotated by `facing_yaw`.
- `heat_step(heat, overheated_until, tick, firing, overheat_ticks, cooldown_ticks)` —
  mirrors `Gadget.repair_heat_step`: sustained fire raises heat; at cap → `overheated_until`
  lockout; decays when not firing. Fire is blocked while `tick < overheated_until`.
- `mark_destroyed(tick)` — `alive=false`, clears `occupant` (server ejects + punishes).

### Placement (deploy)

`GA_LMG_DEPLOY` carries pos + facing dir (like `GA_BREACH_PLACE`). Server validates:
alive/standing owner, Support class with the nest gadget equipped, placement point via
`validate_place` (ground/bounds/range), min separation from another nest, not clipping a
structure. On success: ground-snap, `facing_yaw` from the aim, spawn into `_lmg_nests`,
enforce **one-per-owner** (remove the owner's previous nest first, FOB-style).

### Mount / fire / dismount

- **Mount** (`EA_MOUNT`, nest id): `can_mount` gate → `occupant = id`, bind on the pawn
  (`pawn.mounted_nest = nest_id`, new field; keep it distinct from `in_vehicle`). Server
  slaves the pawn to `seat_world()`, locks movement, and treats the gunner's held weapon as
  the nest MG.
- **Aim**: each tick the gunner's `yaw`/`pitch` feed `turret_yaw`/`pitch` through
  `clamp_traverse` — you physically cannot aim outside the arc (client mirrors the clamp so
  the reticle stops at the edge).
- **Fire**: while mounted and holding fire, a dedicated nest-fire tick (modeled on
  `server/fire.gd`'s mounted path, but a **new** function — vehicle path untouched):
  rate-limited by `fire_interval`, consumes belt `ammo`, raises `heat`, lag-comped hit-scan
  from `muzzle()` along the clamped aim with MG spread + **strong suppression** on those hit.
  Overheat forces a cooldown lockout; empty belt triggers a reload. High capacity + overheat
  are the twin limiters (BattleBit MG-nest feel).
- **Dismount** (`EA_DISMOUNT`): clear `occupant` + `pawn.mounted_nest`, restore the pawn at
  a safe exit pos near the nest (mirror `_safe_exit_pos`), restore its infantry weapon.
- The **gunner is exposed**: normal pawn damage applies while mounted (head over the gun).

### Destruction

The nest carries whole-entity `hp` and is fed by the same damage sweeps that already exist:
bullets (chip), explosions/grenades (heavy), RPG (near-lethal), Engineer sledgehammer. Add
the `_lmg_nests` store to those sweeps in `server/fire.gd` / `server_main.gd`. At `hp ≤ 0`:
`mark_destroyed`, **eject + punish the manning gunner** (knock off + blast damage → likely
down/kill, BattleBit-style), broadcast via the self-healing `EMPLACEMENT_LIST`.

### Replication & client

- **`EMPLACEMENT_LIST`** (server→clients, rebuilt each tick like `GADGET_LIST`/`FOB_LIST`):
  per nest `{id, pos, facing_yaw, turret_yaw, hp_frac, occupant_id, team}`. The client
  full-rebuilds its nest set on each receipt → placements/aim/damage/destroy self-heal. The
  occupant pawn is already in the normal snapshot at the seat pos; the list just says "pawn
  X mans nest Y" so the client poses them at the gun.
- **`SELF_STATE`** trailing append (owner-only): `heat` (0..255), `ammo`, `overheated` bit,
  and a `mounted_nest` id so the client knows to enter FP-manning mode. Additive tail →
  covered by the VERSION 10 bump.
- **Client render**: nest mesh + barrel pivot to `turret_yaw`, damage-state material,
  removal on destroy; remote gunner posed crouched (a `SeatPose`-style helper, nest-local).
- **Client FP manning** (owner): on `mounted_nest != 0`, camera snaps to the sight, mouse
  drives clamped traverse+pitch, fire fires the MG, reticle + **heat bar + ammo counter**
  HUD, "hold [key] to dismount". Screenshot sign-off like P3.

### Bots (fleet gate)

`bot_gadget` gains an LMG-nest branch for Support so the fleet carries it. A dedicated
`NEST` cohort (in `bots/roles.gd`, disjoint index math, capped) runs a `maybe_lmg_nest`
exerciser: deploy near a contested point → mount → sweep-fire enemies within the arc →
dismount when flanked or when the nest dies. This makes the 128-bot conquest_town gate
*provably* place, man, fire, and lose a nest under load.

## Balance defaults (BattleBit-faithful; tunable, live in `data/gadgets.json`)

These must be aggressive enough that the fleet gate actually exercises fire/overheat/
destruction (conservative placeholders would block the gate). Starting point:

| Param | Value | Note |
|---|---|---|
| `hp` | 500 | ~2 RPG or sustained fire to kill |
| `half_arc_deg` | 45 | 90° total traverse |
| `pitch_lo/hi_deg` | 20 / 25 | slight down / up |
| `mg_damage` | 22 / round | body; headshot mult via existing combat |
| `fire_interval` | 0.075 s | ~800 rpm |
| `range_m` | 220 | long suppressive reach |
| `spread` | modest MG cone | suppression over precision |
| `belt` (ammo) | 150 | high capacity |
| `reload_s` | 4.5 | belt swap |
| `overheat_ticks` | ~90 continuous | ~2.25 s sustained → lockout |
| `cooldown_s` | 3.0 | forced cool |
| `mount_range_m` | 1.6 | reach to mount |
| `min_nest_sep_m` | 4.0 | anti-stack |

## Testing (headless TestCase; suite is 1611/0 — keep green)

Deterministic sim proofs (no reliance on emergent bot AI):
- `emplacement_test.gd` — traverse clamp (wrap-aware, edges), `can_mount` gates, seat/muzzle
  geometry, heat_step overheat→lockout→decay, one-per-owner replace.
- `emplacement_fire_test.gd` — mounted fire consumes ammo, respects fire_interval, blocked
  while overheated / reloading / dismounted, hit-scan damages an enemy in-arc and **misses
  out-of-arc**.
- `emplacement_gate_test.gd` — HP depletion via RPG/explosion → destruction → gunner ejected
  + punished (model on `vehicle_gate_test.gd`).
- `protocol_emplacement_test.gd` — `EMPLACEMENT_ACTION` / `EMPLACEMENT_LIST` / SELF_STATE
  tail roundtrip; VERSION 10.
- `bot_lmg_nest_test.gd` — a Support bot deploys + mounts a nest (behavior smoke).
- **128-bot conquest_town fleet gate** on game2 (`docker/stress.sh`) — sim/wire changed, so
  this is required; confirm nests are deployed+manned+fired and the tick-cost budget holds.

## Delivery / landing

Execute via subagent-driven-development. Land via finishing-a-development-branch (fetch
origin FIRST — concurrent M20 pushes to master). New `class_name` scripts (`emplacement.gd`,
any extracted server file) need a real `--import` to regen the class cache before tests.
Client FP work gets a screenshot pass for owner sign-off (PNGs → game2 `~/bf-shots/`).
Update the M19 memory topic on completion.
