# Spec — M5.5 Combat Depth II (Ballistics, Loadout, Suppression, Melee, Throwables)

**Milestone:** [M5.5](../milestones/M5.5-combat-depth-2.md) · **Status:** spec (brainstormed 2026-06-17) · **Follows:** M5 (Land) · **Precedes / interleaves with:** M7 (rendered client)

This spec is the contract for M5.5. It closes the BattleBit-feel gaps surfaced in the 2026-06-17 feature-gap review that the owner accepted: **projectile ballistics (bullet drop + travel)**, **fire-mode selection**, **secondary weapon**, **armor class**, **suppression**, **melee (knife + sledgehammer)**, and **flashbang + impact grenades**. Two accepted items are presentation-only and live in M7, not here: the **death-recap card** (M7-P1 HUD) and **audio design** (M7-P2). Where this spec and the milestone doc differ, **this spec wins**. Constants are initial values, gate-tuned (AGENTS.md §9 — default to BattleBit numbers).

## Objective

Make Blockfire's moment-to-moment gunfight feel like BattleBit before the rendered client locks in its combat feel. Everything here is **server-authoritative**; shared rules live in `shared/sim/` so client prediction and server authority cannot diverge (AGENTS.md §7). VFX/feel pieces (tracers, screen blur, white-out, animations) are deferred to M7 — the same split M4.5 used (smoke-LOS/scope-zoom deferred to M7).

## Cross-milestone dependency — feeds M7 (read first)

The **ballistics model (§1) is an immediate input to the in-flight M7 client** (Checkpoint 2 onward). The client must build **projectile-aware** prediction from the start rather than hit-scan, to avoid a later prediction refactor (owner-directed 2026-06-17). Concretely:

- The client **cosmetically predicts its own tracer** (spawn a local projectile at fire for the visual) but is **not** authoritative for hits — hit/kill confirmation stays the existing **server-confirmed** model (`KILL` + hitmarker, see [client-prediction](client-prediction.md)).
- No ballistics rule logic enters `client/`; the projectile integrator lives in `shared/sim/` so client tracer and server authority share one model (AGENTS.md §7).

## Phasing

M5.5 ships as **three independently-gated phases**, each its own slice of the implementation plan and its own 128-bot fleet gate (mirrors M4.5's shape).

| Phase | Contents |
|---|---|
| **P1 — Ballistics & weapon handling** | Stepped projectiles (drop + travel), fire-mode selection, secondary weapon slot |
| **P2 — Survivability & suppression** | Armor class (Light/Medium/Heavy), suppression (gameplay-affecting) |
| **P3 — Melee & throwables** | Melee (knife + back-stab), sledgehammer demolition, flashbang + impact grenades |

**Profile `[perf]` on the fleet at the end of each phase.** The 128-bot tick rides the budget edge (`snap` ~16 ms dominant; M4.5/M5 peaks ~23–26 ms). **P1 adds the most per-tick work** (live projectiles under full-auto at 128p) — it is the headline perf risk of this milestone. Lean on the degradation knobs (projectile cap, ttl, broadphase culling) before adding cost.

**Explicitly deferred out of M5.5 → M7 (presentation/feel):**

- Tracer / projectile **visuals**, muzzle flash (server spawns/steps the projectile; client renders).
- Suppression **screen blur / shake / audio muffle** (server computes the scalar + accuracy penalty; client renders).
- Flashbang **white-out + deafen audio**, and flashbang **angle-of-view** intensity scaling (v1 server = radius + LOS only).
- Melee / sledgehammer **animations**, weapon-swap animation, fire-mode **HUD indicator**, armor **visual** differences.
- **Death-recap card** (M7-P1 HUD — [hud-ui](hud-ui.md)) and **audio design** (M7-P2 — `docs/specs/audio.md`, reserved).

---

## P1 — Ballistics & weapon handling

### Stepped projectiles (bullet drop + travel time)

Bullet weapons stop being hit-scan. Each shot spawns a lightweight **projectile entity**, server-integrated with gravity and raycast per tick. Bullets are **genuinely in flight** — dodgeable, and the shooter must **lead** targets at range. This is the headline BattleBit-feel change.

- **Entity:** `{id, owner_id, weapon_id, pos: Vector3, vel: Vector3, spawn_tick, dist_traveled, ttl_ticks}`. Lives in a server projectile pool (disjoint ID range, like vehicles/gadgets — not on the per-tick snapshot path; clients spawn their own cosmetic tracer from the fire event).
- **Spawn:** at the shooter's **command-tick** muzzle transform (origin = eye/muzzle offset, dir = look yaw/pitch + the existing server-seeded recoil/spread). Spawning at the command tick keeps high-ping shots originating correctly without a flight-path rewind.
- **Step (per server tick):**
  ```
  vel.y -= GRAVITY * weapon.gravity_scale * dt
  prev = pos;  pos += vel * dt;  dist_traveled += (pos-prev).length()
  hit = raycast(prev -> pos) against broadphase candidates
  if hit: resolve damage (falloff by dist_traveled); apply penetration; else continue
  if dist_traveled >= weapon.max_range or ttl_ticks-- <= 0: expire
  ```
- **Lag compensation:** **present-time stepping, no per-step rewind.** Travel time naturally masks shooter latency (the standard projectile model). This is a deliberate **departure from hit-scan**, which rewinds to the shooter's view time. (Hit-scan-style rewind on a multi-tick projectile is ill-defined; present-time is correct and cheaper.)
- **Broadphase:** reuse the interest-grid / spatial index. Each step's segment is tested only against enemy hitboxes + structures + vehicles in the cells the segment crosses — bounded cost per projectile.
- **Penetration:** reuse the M4.5 `march()` penetration model — on hitting a penetrable piece, damage the piece and continue with `remaining × transmit_factor` (max 1 penetration per shot, unchanged).
- **Damage:** unchanged region model (head sphere + body capsule, headshot mult), now with **distance-traveled falloff** instead of a flat cutoff. Headshot instant-kill bypass and DBNO routing from M4.5 are preserved (armor may modify headshot lethality — §2).
- **Determinism:** integration is float-deterministic and seeded identically to today's spread/recoil; a recorded fire stream reproduces the same impacts.

**Per-weapon fields (added to `weapon.gd` / weapon data):** `muzzle_velocity` (m/s), `gravity_scale` (drop multiplier; high-velocity rounds < 1.0), `max_range` (becomes distance-traveled cutoff), `projectile_ttl_ticks`. BattleBit-faithful muzzle velocities (gate-tuned): SMG/pistol low, AR mid, DMR/sniper high.

**Cost controls (perf gate is on these):**
- `MAX_LIVE_PROJECTILES` global cap; oldest expires if exceeded.
- Hard `projectile_ttl_ticks` so strays don't accumulate.
- Broadphase culling so an in-flight bullet over empty space is ~free.
- Degrade-before-drop: if the tick budget is threatened, lower the projectile cap / raise step granularity before cutting bot count.

### Fire-mode selection

- Weapon data gains `fire_modes: Array` (subset of `AUTO / SEMI / BURST`) + `burst_count`.
- Input carries the **selected fire mode** (cycle key, default **B**). The server enforces it in the fire gate: `SEMI` = one shot per trigger-press edge, `BURST` = `burst_count` shots then forced release, `AUTO` = continuous at `rpm`.
- Default available modes per weapon match BattleBit (e.g. AR = AUTO/SEMI/BURST, DMR = SEMI, SMG = AUTO/SEMI).

### Secondary weapon (sidearm)

- `loadout.gd` gains a **secondary slot** drawn from a **sidearm pool** (pistols; a class may restrict, e.g. a machine-pistol option). Primary + secondary, as BattleBit.
- Each weapon keeps **independent** mag/reserve state. The pawn tracks `active_weapon_slot`; a **swap input** (default `1`/`2` or mouse-wheel) switches. **Quick-swap is faster than a reload** — that is its tactical purpose (`WEAPON_SWAP_TICKS` < reload).
- Server validates fire/reload against the active slot. RPG (Engineer weapon-slot choice, M4.5) occupies the **primary** slot and is unaffected.

---

## P2 — Survivability & suppression

### Armor class (Light / Medium / Heavy)

A single **loadout choice** bundling the BattleBit armor tradeoff (helmet folded into the tier — no separate helmet/vest/backpack slots, owner-chosen simplification 2026-06-17).

| Class | `body_damage_mult` | `move_speed_mult` | Ammo/throwable capacity | Headshot behavior |
|---|---|---|---|---|
| LIGHT | 1.00 | 1.00 | fewest | normal headshot lethality |
| MEDIUM | 0.85 | 0.95 | default | normal |
| HEAVY | 0.70 | 0.90 | most | low-power headshots (e.g. pistol) **not** an instant kill |

- Applied in `combat.gd` **after** hit-region resolution and **before** the DBNO/lethality check: `dmg *= body_damage_mult` for body hits; for head hits, HEAVY reduces headshot lethality so a sub-threshold headshot routes to heavy damage / DBNO instead of instant kill.
- `move_speed_mult` multiplies the M2 stance speeds in `pawn.gd`.
- Capacity scales starting mag-reserve and gadget/throwable counts at spawn.
- All values gate-tuned; HEAVY must remain killable (avoid bullet-sponge feel).

### Suppression (gameplay-affecting + visual)

Being shot at degrades your aim — the BattleBit suppression mechanic. **Depends on P1 projectiles** for near-miss detection (hence the phase order).

- **State:** `Pawn.suppression: float` in `[0,1]`. Each tick, every live enemy projectile (or blast) passing within `SUPPRESS_RADIUS` of the pawn adds `SUPPRESS_PER_NEARMISS` (scaled by closeness); the scalar **decays** `SUPPRESS_DECAY` per tick.
- **Effect (server, in `combat.gd`):** above `SUPPRESS_THRESHOLD`, the pawn's **effective spread is raised** and an **aim-sway** term added, scaled by `suppression`. This modifies shot resolution only — never lag-comp or authority.
- **Replication:** `suppression` quantized to **1 byte** in the pawn packed state, so the M7 client renders blur/shake/muffle from it.
- **Bots:** suppression applies to bot fire too (their shots get the same spread penalty), so the gate exercises it; bot tactical *reaction* to being suppressed is M7.5.

---

## P3 — Melee & throwables

### Melee — knife + back-stab

- **Knife** is a **melee loadout slot** (default knife; cosmetic variants later). A universal **quick-melee** action (default **V**) uses it.
- **Resolution (server):** short cone, `MELEE_RANGE ≈ 1.5 m`, vs the nearest valid enemy in front. **Back-stab** (attacker within `BACKSTAB_ARC` of directly behind the target) = **instant kill** (bypasses DBNO, like a headshot). Frontal hit = `MELEE_DAMAGE` (high, **not** instant — routes through normal damage/DBNO). Reuses the hitbox path; present-time (point-blank, rewind negligible).
- `MELEE_COOLDOWN_TICKS` between swings.

### Sledgehammer — fast demolition

- A **melee tool** (slot/option) whose role is **fast structure destruction** (BattleBit's pickaxe/sledge). Per-hit applies `SLEDGE_STRUCTURE_DAMAGE` (high) to the targeted structure cell via the **M4 structure-damage + bucket-delta path**; `SLEDGE_PAWN_DAMAGE` (moderate) vs pawns.
- **Availability:** **Engineer-only** (owner-directed 2026-06-17). The sledgehammer is the Engineer's melee tool; other classes use the standard knife. `loadout.gd` rejects sledgehammer selection for non-Engineer loadouts (same pattern as RPG being Engineer-only in M4.5). Quick-melee (knife) remains universal.

### Flashbang + impact grenades

Extend the M4 `Grenade` type enum (`FRAG | SMOKE`) with **`FLASHBANG`** and **`IMPACT`**, data-driven in `data/gadgets.json`, reusing the ballistic + detonation model.

- **Flashbang:** on detonation, blind/deafen each pawn within `FLASH_RADIUS` **with line-of-sight** (occlusion blocks it — reuse the structure/terrain occlusion query). Sets `blind_until_tick` on the pawn (replicated), decaying over `FLASH_BLIND_TICKS`. **No** falloff damage. Angle-of-view intensity scaling deferred to M7; v1 = radius + LOS, full blind. Client renders white-out + deafen (M7); bot perception is suppressed while blinded (full bot reaction → M7.5).
- **Impact grenade:** a frag variant with **zero fuse** — detonates on **first surface/pawn contact** (reuse the RPG contact-detonation path) rather than a timed fuse. Same blast/falloff/FF-off as frag.

---

## Module layout (extends M4.5 / M5)

```
shared/sim/
  projectile.gd    NEW  Projectile record + pure integrate/step/expire helpers; broadphase ray segment
  ballistics.gd    NEW  (or fold into projectile.gd) muzzle transform, gravity/drop, distance falloff
  combat.gd        (mod) projectile hit resolution + penetration reuse; armor damage mult; suppression
                          spread/sway term; fire-mode gate; melee/back-stab resolution
  pawn.gd          (mod) + suppression: float, blind_until_tick, active_weapon_slot;
                          move_speed_mult from armor class; melee cooldown
  weapon.gd        (mod) + muzzle_velocity, gravity_scale, projectile_ttl, fire_modes, burst_count
  loadout.gd       (mod) + secondary (sidearm) slot, armor_class, melee slot
  grenade.gd       (mod) + FLASHBANG / IMPACT types (blind, zero-fuse contact)
shared/net/
  protocol.gd      (mod) + fire-mode + active-slot + swap in input; projectile spawn is derivable
                          from the fire event (no per-tick projectile stream); suppression + blind in
                          pawn packed state; DEATH_INFO for the M7 death-recap card
data/
  weapons (mod)    + ballistics, fire_modes, sidearm pool; armor_classes; melee defs
  gadgets.json     (mod) + flashbang, impact grenade
server/server_main.gd  (mod) projectile pool tick (spawn/step/expire/resolve); suppression accrual+decay;
                              armor application; fire-mode + weapon-swap; melee; flashbang blind; telemetry
                              (live projectiles, suppression events, armor TTK, melee/backstab, flash, impact)
bots/bot_driver.gd     (mod) lead moving targets (projectile travel); switch fire modes; use secondary;
                              pick an armor class; quick-melee at point-blank; throw flashbang before a push
ci/m5.5_*_test.sh      NEW   per-phase gates (P1 projectiles/budget, P2 armor/suppression, P3 melee/throwables)
```

AI tuning of *feel* (lead accuracy, suppression reaction) is deferred to the M7 visual pass (AGENTS.md §10); M5.5 proves the **mechanics** deterministically and the **budget** on the fleet.

---

## Constants (initial values; gate-tuned)

| Const | Value | Meaning |
|---|---|---|
| `GRAVITY` | reuse grenade g | base gravity for projectile drop |
| `MAX_LIVE_PROJECTILES` | 1024 | global live-bullet cap (perf knob) |
| `WEAPON_SWAP_TICKS` | 12 (0.4 s) | quick-swap time (< reload) |
| `BURST_COUNT` (default) | 3 | shots per burst |
| `SUPPRESS_RADIUS` | 2.5 m | near-miss radius that suppresses |
| `SUPPRESS_PER_NEARMISS` | 0.15 | suppression added per near-miss (closeness-scaled) |
| `SUPPRESS_DECAY` | 0.04 /tick | per-tick decay |
| `SUPPRESS_THRESHOLD` | 0.25 | min suppression before accuracy penalty |
| `MELEE_RANGE` | 1.5 m | melee reach |
| `BACKSTAB_ARC` | 60° | rear arc for instant-kill back-stab |
| `MELEE_DAMAGE` | 50 | frontal melee damage (non-lethal-in-one) |
| `MELEE_COOLDOWN_TICKS` | 24 (0.8 s) | between swings |
| `SLEDGE_STRUCTURE_DAMAGE` | high | per-hit cell damage (fast demolition) |
| `FLASH_RADIUS` | 8 m | flashbang blind radius (LOS-gated) |
| `FLASH_BLIND_TICKS` | 90 (3 s) | blind/deafen duration |
| armor `body_damage_mult` | 1.0 / 0.85 / 0.7 | Light / Medium / Heavy |
| armor `move_speed_mult` | 1.0 / 0.95 / 0.9 | Light / Medium / Heavy |

---

## Budgets

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held). **P1 projectiles are the risk**: O(live projectiles × broadphase steps). Cap + ttl + culling keep it bounded; profile `[perf]` and lean on the projectile cap before anything else. P2/P3 add O(N) suppression accrual and O(1) melee/contact checks — cheap relative to `snap`.
- **Bandwidth:** projectiles **do not** ride the per-tick snapshot (clients derive a cosmetic tracer from the reliable fire event). Suppression (1 byte) + blind (packed) add ≤2 bytes/pawn. Fire-mode/swap are input-side. No new per-tick stream.

---

## Gate (per phase, 128-bot fleet + deterministic tests)

Mechanics proven **deterministically** (scripted scenario, AGENTS.md §10); fleet proves **budget + match completion**; AI-dependent counters **reported, not gated**.

- **P1:** deterministic — a led shot at a moving target connects with drop/travel; penetration still works through a projectile. Fleet — kills register via projectiles; **tick + bandwidth budget held under full-auto at 128p** (the headline test); fire-mode + secondary exercised.
- **P2:** deterministic — identical shot deals less to HEAVY than LIGHT; a suppressed shooter's effective spread rises. Fleet — armor TTK differs by class; suppression events observed; budget held.
- **P3:** deterministic — back-stab instant-kills; frontal melee does not one-shot; sledge demolishes a cell fast; flashbang blinds an in-LOS pawn; impact grenade detonates on contact. Fleet — melee/back-stab, sledge, flash, impact events observed; budget held.
- **All phases:** Conquest still reaches a winner.

---

## Explicit non-scope

- **Per-bullet client hit authority** — server stays authoritative for hits; client tracer is cosmetic.
- **Hit-scan rewind for projectiles** — projectiles are present-time (travel masks latency).
- **Separate helmet / vest / backpack slots** — folded into the single armor class (owner-chosen).
- **Flashbang angle-of-view intensity, white-out/deafen rendering** — M7.
- **Tracer / suppression / melee / armor VFX + animation** — M7.
- **Death-recap card** — M7-P1 ([hud-ui](hud-ui.md)).
- **Audio (bullet crack/whiz, footsteps, occlusion, suppressor signature, suppression muffle)** — M7-P2 (`docs/specs/audio.md`, reserved).
- **Bot tactical reaction to suppression/flash/lead** — M7.5 (mechanics here apply to bots; *smart* reaction is the AI milestone).
- **No sliding / parachute / swimming** — unchanged design decision (M4.5).

## Specs

- This spec is the brainstorm-of-record for M5.5. Per-phase implementation plans go in `docs/plans/` (`writing-plans`), executed via `subagent-driven-development` in the M4.5 mould.
