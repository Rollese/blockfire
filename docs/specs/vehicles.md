# Spec — M5 Vehicles (Land + Air)

**Milestone:** [M5 — Vehicles](../milestones/M5-vehicles.md) · **Status:** drafted (brainstormed 2026-06-16)
**Phasing:** **P1 = Land + full vehicle substrate** (this spec's detailed scope). **P2 = Air** (reuses the P1 substrate; sketched at the end). Each phase is its own 128-bot fleet gate, like M4/M4.5.

This spec covers **P1** in implementation detail and records the **P2** shape so the substrate is built air-ready. Rules that run in the sim live in `shared/sim/` so client prediction (M7) and server authority can't diverge (AGENTS.md §7).

---

## 1. Purpose & design decisions (ratified in brainstorming)

Networked, server-authoritative vehicles. P1 ships **one land vehicle** — an **armored transport** with driver / passengers / gunner — through a complete substrate: continuous replication, seats + enter/exit, a vehicle HP system, RPG/explosive anti-vehicle damage, the Engineer repair kit, anti-cheat Layer 2 input validation, and minimal bot occupancy. P2 adds air vehicles on the same substrate.

Ratified decisions:

1. **Phase P1 = land + substrate; P2 = air.** De-risks the tick/bandwidth budget by proving the snapshot/HP/repair path on land first.
2. **P1 roster = one armored transport with a mounted gun.** Seats: 1 driver, ~3 passengers (ride-only in v1), 1 gunner (server-resolved hit-scan). Armored HP so the RPG matters and the repair kit has a job.
3. **Fully server-authoritative; no client-side vehicle prediction in M5.** Driver/gunner send *intent*; the server integrates physics; vehicle + occupant state replicate and clients interpolate like remote pawns. The wire format stays forward-compatible for M7 driver prediction. (Consistent with ammo/fire/movement reconciliation already deferred to M7.)
4. **Replication = Approach A:** vehicles are first-class replicated entities **multiplexed into the existing `SNAPSHOT` message**, reusing the baseline+delta+ack+interest machinery. (Rejected: a separate vehicle channel — duplicates machinery for no gain at ~12 vehicles; event-based-like-structures — wrong fit for continuously-moving entities.)
5. **Authoritative motion is custom kinematic** (deterministic `shared/sim/` code), never an engine rigidbody. **Ragdolls / wreck debris / cosmetic suspension are deferred to M7** — client-side, cosmetic, non-replicated, driven off authoritative events (`KILL`, `VEHICLE_DESTROYED`), using Godot's built-in physics (Jolt + `PhysicalBone3D`). They never touch `shared/sim/` or the snapshot.
6. **Team-locked vehicles.** Spawn at team bases; only the owning team may enter; auto-respawn at base after destruction. Enemy theft is deferred.
7. **Seated occupants are bullet-immune (hull absorbs); the exposed gunner is the exception; vehicle destruction kills all occupants.** The explosive blast is the anti-vehicle threat, not per-window bullet penetration (deferred).

---

## 2. Architecture & module layout

New modules (all in `shared/sim/` unless noted):

| Module | Role |
|---|---|
| `vehicle.gd` (`class_name Vehicle extends RefCounted`) | Authoritative entity. Fields: `id`, `type`, `team`, `pos`, `heading` (body yaw), `turret_yaw`, `velocity`, `hp`, `seats: Array[int]` (seat-index → occupant pawn id; `0` = empty), `respawn_tick`. Methods: `step(dt, cmd)` (physics), `seat_world(seat) -> Transform/Vector3` (seat world pos + facing), `to_state() -> VehicleState`. |
| `vehicle_state.gd` (`class_name VehicleState`) | Replicated view: `pos`, `heading`, `turret_yaw`, `hp`, `type`, `seat_occupancy: Array[int]`. The vehicle analogue of `EntityState`. `clone()`. |
| `vehicle_catalog.gd` (`class_name VehicleCatalog`) + `data/vehicles.json` | Data-driven defs: `max_hp`, `max_speed`, `reverse_speed`, `accel`, `drag`, `turn_rate`, `seats` (count + local offsets + role: driver/passenger/gunner), `mounted_weapon` (fire_interval/damage/range/turret offset), `vehicle_dmg_*` resist (optional armor multiplier), `respawn_ticks`. Same load pattern as `gadgets.json`/`fortifications.json`. |
| `input_validate.gd` (`class_name InputValidate`) | Anti-cheat L2: bound-check/clamp inputs at the sim boundary (infantry + vehicle). |
| `World` (extend) | Gains `vehicles: Dictionary[int → Vehicle]`. |
| `SimLoop` (extend) | Integrates vehicles after pawns; slaves seated occupants; `vehicle_state_map()`. |

Server (`server/server_main.gd`) wires: vehicle spawning at map load, `VEHICLE_ACTION` handler, `_step_vehicles()` (physics), `_resolve_vehicle_fires()` (gunner), vehicle pass inside `_blast_at()`, `_step_repairs()` (latched repair), vehicle relevance + encode in `_send_snapshots()`, `VEHICLE_DESTROYED` broadcast, vehicle respawn.

---

## 3. Replication (Approach A)

- **Disjoint IDs:** `const VEHICLE_ID_BASE := 0x40000000`. Vehicle ids = `VEHICLE_ID_BASE + n`, so they never collide with pawn ids (1–128) and the pawn fire broad-phase grid stays pawn-only.
- **Wire — `SNAPSHOT` body gains a trailing vehicle section** (after the existing pawn records):
  - `vehicle_count: u16`, then per vehicle `{id: u32, flags: u8 (ENTER/LEAVE/CHANGED), field_mask: u8, fields…}`.
  - Vehicle field mask bits: `VF_POS_X/Y/Z`, `VF_HEADING`, `VF_TURRET`, `VF_HP`, `VF_SEATS`, `VF_TYPE`. `pos` via `Quantize.enc_pos`; angles via `Quantize.enc_angle`; `hp` quantized (u16 raw, or u8 scaled — few vehicles, send raw u16); `seats` as a small occupant-id list (only on change); `type` only on ENTER.
  - Codec lives in `snapshot.gd` (`encode_vehicles`/`decode_apply_vehicles`), reusing `Quantize`.
- **Per-client history** stores `{pawns: …, vehicles: …}`; baseline_seq/ack/keyframe logic unchanged (a keyframe clears both views).
- **Interest:** ~8–16 vehicles total → vehicle relevance is a **plain radius scan** per client (`INTEREST_RADIUS`), NOT inserted into the pawn grid. Cost ≈ clients × vehicles ≈ negligible.
- **Occupants stay ordinary pawns.** Each tick `SimLoop` sets a seated occupant's `pawn.pos = vehicle.seat_world(seat)` (and the gunner's facing), so occupants replicate through the existing pawn path. The client learns the binding from the vehicle's `seat_occupancy` (no spare state-byte bit — all 8 are used through `climbing`).
  - *Bandwidth note (deferred to M7):* seated occupants re-send their (vehicle-driven) position every tick; culling them and deriving client-side from the seat transform is a listed optimization, not v1.

---

## 4. Seats & enter / exit flow

New wire message **`VEHICLE_ACTION` (Msg = 18)**, action-byte multiplexed like `GADGET_ACTION`:

| Action | Payload | Server validation & effect |
|---|---|---|
| `VA_ENTER` | `{vehicle_id: u32, seat_hint: u8}` | Pawn alive, not downed, not already seated; vehicle exists, **same team**, hull within `ENTER_RANGE`; seat (or nearest free if hint taken) empty. → assign seat, set `pawn.in_vehicle`/`pawn.seat`, mark seat occupied. Driver = seat 0. |
| `VA_EXIT` | `{}` | Place pawn at an exit offset beside the hull (clamped to ground/platform floor), clear seat + binding; normal movement resumes next tick. |

**Occupant model while seated:**
- Movement: a seated pawn early-returns from `Pawn.step()` (same pattern as `climbing`/`vaulting`); `SimLoop` writes `pawn.pos = vehicle.seat_world(seat)` each tick.
- Driver look is cosmetic (steering is `move_x/move_y`); gunner look = turret aim.
- Damage: hull absorbs small-arms → **seated occupants immune to bullets**; **gunner exposed** (turret hit-scan/blast can hit them). Vehicle **destruction kills all occupants** via the existing `_apply_pawn_damage` BLAST path.
- A driver leaving/dying parks the vehicle (throttle→0, drag halts it). Seated-pawn death/disconnect frees the seat.

---

## 5. Land physics (server-authoritative, deterministic — `Vehicle.step`)

- **Intent:** throttle = `cmd.move_y ∈ [−1,1]`, steer = `cmd.move_x ∈ [−1,1]` (clamped by `InputValidate`).
- **Longitudinal:** `speed += throttle * accel * dt`, clamp to `max_speed` fwd / `reverse_speed` back; coasting applies linear `drag`; light brake when throttle opposes motion.
- **Steering is speed-gated:** `heading += steer * turn_rate * dt * turn_factor(speed)`, where `turn_factor → 0` near standstill (no wheeled pivot) and tapers at top speed.
- **Velocity** = `forward(heading) * speed`; `pos += velocity * dt`.
- **Vertical/terrain:** gravity + ground floor (`pos.y ≥ 0`) + **platform floor** via the existing `Ladder.platform_floor(platforms, …)`; world-bounds clamp to `WORLD_HALF`. No suspension/ramp model in v1.
- **Collision (coarse, v1):**
  - vs **structures:** forward `StructureStore.march` along the step; **stop at contact** (no driving through bases). No crush damage.
  - vs **pawns (roadkill):** **deferred** (not needed for the gate; adds a damage path).
  - vs **vehicles:** non-colliding in v1 (rare overlap with ~1–2 transports/team).

Cost: ~12 float-op integrations + one `march` per moving vehicle; sub-µs aggregate (folded into the `veh` `[perf]` bucket).

---

## 6. Vehicle HP, anti-vehicle damage, repair & the mounted gun

### HP & destruction
- `Vehicle.hp` ∈ `[0, max_hp]` (e.g. **1000**), replicated on change (rare → cheap).
- **Damage in** comes from **explosive blasts** (vehicles are bullet-immune per §4). `_blast_at()` — the single path all blasts already share (frag/RPG/C4/mine) — gains a **vehicle pass**: for each vehicle in radius, apply `Grenade.falloff_damage(center, vehicle.pos, vehicle_dmg, radius)`. Each blast source carries its own **`vehicle_dmg`** (data-driven): **RPG high** (anti-vehicle by design), **C4 meaningful**, frag/mine small chip. An optional per-vehicle armor multiplier may scale it.
- **On `hp ≤ 0`:** mark destroyed → kill all occupants (existing `_apply_pawn_damage`, `Revive.Source.BLAST`) → broadcast **`VEHICLE_DESTROYED` (Msg = 19)** (reliable, like `KILL`) → schedule respawn at base after `respawn_ticks`. The vehicle emits a snapshot LEAVE while dead and re-enters on respawn.

### Engineer repair kit (defined in M4.5, wired here)
- New gadget kind **`KIND_REPAIR`** in `gadgets.json`; Engineer owns **C4 *and* repair** (per the M4.5 class table), multiplexed by `GADGET_ACTION` sub-action — no class-assignment change.
- New sub-actions **`GA_REPAIR_START` / `GA_REPAIR_STOP`**, **latched** like the medic/support active-give (`_repairing` dict; validity re-checked each tick so a dropped packet under fleet starvation doesn't break the hold).
- **Unlimited but rate- and duty-cycle-limited** — mirrors the medic active heal / support active ammo family (no per-spawn pool; the cost is the Engineer standing exposed at the hull). Each tick a held repair, with the Engineer alive & within `REPAIR_RANGE` of a **friendly, damaged** vehicle and **not overheating**: `vehicle.hp = min(max_hp, hp + REPAIR_RATE)`.
- **Overheat / cooldown** (BattleBit model): continuous use accumulates heat (`_repair_heat[engineer_id]`, +1 per repairing tick, decays −1 per non-repairing tick). When heat reaches `REPAIR_OVERHEAT_TICKS` the tool overheats → a `REPAIR_COOLDOWN_TICKS` (**5 s**) lockout during which repair is disabled; heat resets when the lockout ends.
- **Repair economy is pinned to the RPG:** one overheat burst = `REPAIR_OVERHEAT_TICKS × REPAIR_RATE` = **500 HP ≈ one rocket's damage ≈ 50 % of the hull**. So one Engineer burst undoes one rocket; fully reversing a 2-rocket kill takes **two bursts across the cooldown**. The gate is the cooldown duty cycle, not a finite charge pool.

### Mounted gun (gunner)
- Gunner sends look `yaw/pitch` (turret aim) + `BTN_FIRE`. Server resolves a **hit-scan** from the turret muzzle (`vehicle.pos` + rotated turret offset, `turret_yaw` + gunner pitch) through the **existing `Combat`/`Hitbox` + lag-comp path**, FF-off, rate-limited by the weapon `fire_interval`. Thin `_resolve_vehicle_fires()` parallels `_resolve_fires()`. `turret_yaw` is replicated in `VehicleState`.
- v1 mounted gun is **anti-infantry hit-scan** only (vehicle-vs-vehicle balance deferred to the tank/air tier).

---

## 7. Anti-cheat Layer 2 — server-side input validation

`shared/sim/input_validate.gd`, called by the server at the sim boundary (`_step_movement`, vehicle/gadget handlers). **Clamp, don't reject** (rejecting risks desync); record anomalies.

- **Infantry:** `move_x/move_y` clamped to `[−1,1]` and renormalized; per-tick yaw/pitch delta capped at `MAX_VIEW_RATE` (logged if exceeded); fire cadence vs ammo already enforced (`fire_interval` + ammo) — validator records anomalies.
- **Vehicle:** throttle/steer clamped to `[−1,1]`; turret yaw/pitch rate capped; seat actions bound-checked (valid id, in range, seat exists).
- Telemetry: `_ac_violations` counter. This is the **earliest landing point** for ADR-0004's Layer 2 (see [anti-cheat-matchmaking spec](anti-cheat-matchmaking.md) / [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md)); deliberately lightweight.

---

## 8. Minimal bot vehicle behavior (`bots/bot_driver.gd`)

Vehicles appear in the bot's decoded snapshot (Approach A). Kept a **minority** so the decisive-win convergence (the M3+ gate property) isn't destabilized.

- A capped subset (`MAX_VEHICLE_BOTS` per team), when an own-team vehicle is free & nearby: path to it → `VA_ENTER` (first bot = driver seat 0, next few = passenger/gunner) → **driver** sends throttle/steer toward the team's current objective → near the objective (or on contact) all occupants `VA_EXIT` and resume normal infantry capture/fight AI.
- A gunner bot may fire toward an acquired enemy (bounded by the infantry burst heuristic) to exercise `_resolve_vehicle_fires`; full vehicle combat AI is later.
- A bot whose vehicle is destroyed respawns and continues on foot.
- Knob: `MAX_VEHICLE_BOTS` (throttle drivers, like `MAX_BOT_BUILDS`/`MAX_BOT_GRENADES`).

---

## 9. Telemetry, budget & degradation knobs

- New `[perf]` phase bucket **`veh`** (physics + vehicle fire + vehicle snapshot-encode) — proves it's cheap; re-profile if it regresses.
- New `[telemetry]` counters: `vehicles_alive`, `enters`, `exits`, `veh_destroyed`, `repairs` (HP restored), `repair_overheats`, `rkt_vs_veh` (rockets that hit a vehicle), `ac_viol`.
- **Degradation knobs:** `MAX_VEHICLES` (roster cap), `MAX_VEHICLE_BOTS`, an optional vehicle snapshot stride (unlikely needed at ~12 vehicles).
- **Budget watch:** `snap` (~16 ms) remains the dominant cost; the 128-bot fleet peak rides the edge (~23–29 ms). Profile `[perf]` on the fleet early; lean on knobs before adding per-tick work.

---

## 10. Test plan

**Unit (TDD, `tests/*_test.gd` extending `TestCase`):**
- Vehicle physics determinism: identical inputs → identical trajectory; speed-gated steering (no standstill pivot); reverse/drag/clamp.
- Seat enter/exit validation: range, team-lock, full seats, double-board, exit placement.
- Occupant slaving: seated `pawn.pos` tracks `seat_world`; exit restores movement.
- HP/destruction: blast reduces hp by falloff; `hp ≤ 0` kills occupants + schedules respawn; per-source `vehicle_dmg` (RPG ≫ frag).
- Repair: restores hp at `REPAIR_RATE`; stops at full / out-of-range; **overheats after `REPAIR_OVERHEAT_TICKS` continuous use → `REPAIR_COOLDOWN_TICKS` lockout; heat decays when not repairing; resumes after cooldown**; no pool / unlimited across the life.
- Mounted gun: hit-scan from turret transform hits an enemy via the shared `Combat`/`Hitbox` path; respects `fire_interval`.
- `VehicleState` codec roundtrip (encode→decode equality) and the **multiplexed snapshot roundtrip** (pawns + vehicles together; ENTER/CHANGED/LEAVE; keyframe reset).
- `InputValidate` clamps (throttle/steer/move/view-rate).

**128-bot fleet gate** (`docker/run-m5-p1-gate.sh`, server pinned to **P-cores 0–15**; persisted `srvlog-<ts>.log` as evidence):
- **Pass criteria:**
  - valid winner;
  - **peak tick < 33.3 ms**; aggregate bandwidth reported (within budget);
  - `enters ≥ 1` **and** a measurable transport (a driven vehicle carries an occupant ≥ **30 m** from its boarding point — tracked server-side and reported);
  - `veh_destroyed ≥ 1` via RPG (`rkt_vs_veh ≥ 1`) — proves RPG → HP → destruction end-to-end;
  - `repairs ≥ 1` — proves the repair kit restores HP under load.

---

## 11. Constants (initial; tune at the gate)

| Const | Value (initial) | Meaning |
|---|---|---|
| `VEHICLE_ID_BASE` | `0x40000000` | disjoint id range from pawns |
| `VEHICLE_MAX_HP` (transport) | 1000 | armored transport hull HP |
| `ENTER_RANGE` | 3.0 m | board reach from hull |
| `VEHICLE_RESPAWN_TICKS` | 450 (15 s) | respawn at base after destruction |
| transport `max_speed` / `reverse_speed` | 18 / 6 m/s | arcade top speeds |
| transport `accel` / `drag` / `turn_rate` | tune | longitudinal accel, coast drag, max yaw rate |
| `RPG_VEHICLE_DMG` | 500 | RPG blast vehicle damage at centre (50 % hull; exactly 2 rockets kill) |
| `C4_VEHICLE_DMG` | 500 | C4 vehicle damage at centre (50 % hull) |
| `FRAG_VEHICLE_DMG` | 80 | frag chip damage |
| `REPAIR_RATE` | 10 HP/tick (300 HP/s) | Engineer repair speed |
| `REPAIR_OVERHEAT_TICKS` | 50 (1.67 s) | continuous-use limit → one burst = 500 HP (one rocket / 50 % hull) |
| `REPAIR_COOLDOWN_TICKS` | 150 (5 s) | overheat lockout (BattleBit) |
| `REPAIR_RANGE` | 4.0 m | repair reach from hull |
| mounted gun `fire_interval` / `damage` / `range` | tune | anti-infantry hit-scan |
| `MAX_VIEW_RATE` | tune (rad/tick) | anti-cheat view-rate cap |
| `MAX_VEHICLES` | ~4 (2/team) | roster cap (degradation knob) |
| `MAX_VEHICLE_BOTS` | small (per team) | bot-driver cap (degradation knob) |

*(Vehicle-specific values live in `data/vehicles.json`; blast `vehicle_dmg` values live with each blast source's gadget def.)*

---

## 12. P2 — Air (sketch; built on the P1 substrate)

P2 reuses everything above (replication, seats/enter-exit, HP/repair/RPG wiring, anti-cheat, bots) and adds:
- An **air flight model** in `Vehicle.step` (a `domain: LAND/AIR` branch or a `vehicle_air.gd` helper): collective/throttle for altitude, pitch/roll/yaw, gravity + lift; bounded by `WORLD_HALF` and a ceiling. Still custom-kinematic, deterministic, server-authoritative.
- **Air bots** that occupy + transport (and minimally hold altitude toward an objective).
- Its own 128-bot fleet gate (`run-m5-p2-gate.sh`) with the same budget criteria plus air-occupy/transport evidence.

Open P2 questions (defer to P2 brainstorming): air vehicle roster (transport heli vs. armed), landing/auto-hover assist, anti-air (RPG-vs-air viability vs. a dedicated tool).

---

## Out of scope for M5 (explicit)

- Client-side vehicle prediction/reconciliation (M7, with the rendered client).
- Ragdolls / wreck debris / cosmetic vehicle physics (M7, client-cosmetic, engine-physics-backed).
- Enemy vehicle theft; vehicle-vs-vehicle weapon balance; roadkill; hull-hull collision; per-window bullet penetration into occupants; passenger fire-from-seat (M7).
- Suspension / terrain ramp model.
