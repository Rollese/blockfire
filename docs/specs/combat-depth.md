# Spec — M4.5 Combat Depth & Class Identity

**Milestone:** [M4.5](../milestones/M4.5-combat-depth.md) · **Status:** spec (brainstormed 2026-06-15) · **Follows:** M4 (closed) · **Precedes:** M5

This spec is the contract for M4.5. It refines the milestone doc with the design decisions taken during brainstorming. Where this spec and the milestone doc differ, **this spec wins** (the milestone doc is the roadmap entry; this is the build contract). Constants are initial values, gate-tuned.

## Objective

Give Blockfire full class identity and combat depth before vehicles arrive: a down-but-not-out (DBNO) survival loop with revives, the full class gadget kit (C4, mines, active medic/ammo tools, RPG), bullet penetration, weapon attachments, and movement extensions (ladders, vaulting, drop-shoot prevention). All systems are **server-authoritative**; shared rules live in `shared/sim/` so client prediction and server authority cannot diverge (AGENTS.md §7).

## Phasing

M4.5 ships as **three independently-gated phases**, each its own slice of the implementation plan and its own 128-bot fleet gate (mirrors M4's two-phase shape).

| Phase | Contents |
|---|---|
| **P1 — Survivability** | DBNO state, bleed-out, self-bandage, revive (+ medic 2×), ticket-economy hook, instant-kill bypass + finishing |
| **P2 — Combat depth** | Class gadgets (C4, mine/claymore, **active** medic tool, **active** ammo tool), RPG (Engineer-only), bullet penetration, weapon attachments |
| **P3 — Movement** | Ladder climbing, vaulting, drop-shoot prevention |

**Profile `[perf]` on the fleet at the end of each phase, not just at milestone close.** The 128-bot tick rides the budget edge (~29.5 ms clean, one 35.39 ms contention spike in M4) and `snap` (~16 ms) is the dominant pre-existing cost. P2 adds the most per-tick work; lean on the degradation knobs before adding cost.

**Explicitly deferred out of M4.5:**

- **Body dragging → M7.** Its only observable effect is the carried ragdoll, and all ragdoll/client rendering is already an M7 concern; a headless bot gate cannot exercise it. Moved to M7 to land with its rendering. (Removes `GRAB_BODY`/`RELEASE_BODY` and `carrier_id` from this milestone.)
- Vehicle repair kit (Engineer) — defined in M5, needs vehicle HP.
- RPG anti-vehicle damage — M5 (structure + pawn damage active from M4.5).
- Smoke grenade LOS culling / VFX — M7 (server zone data already exists from M4).
- Scope zoom, suppressor audio, attachment visuals — M7 (server applies stat multipliers only).

---

## P1 — Survivability

### DBNO (down-but-not-out)

Health reaching 0 normally moves a pawn to **DOWNED** rather than dead.

- **State:** `Pawn` gains `DOWNED` (a state distinct from `alive=false`). New fields: `is_downed: bool`, `bleed_health: int` (HP below 0, floored at `BLEEDOUT_FLOOR`), `bandage_count: int`, `bleed_halted: bool`.
- **Behavior while DOWNED:** immobile except crawl (`DOWNED_CRAWL_SPEED`); cannot fire; cannot use gadgets; bleeds `BLEED_RATE` HP/tick unless `bleed_halted`. Server keeps simulating and replicating the pawn (others see the downed body).
- **Immune to weapon damage while DOWNED (BattleBit-style):** once downed, a pawn takes **no further damage** from bullets or blasts — there is no "finishing." A downed pawn resolves only by passive bleed-out or a teammate revive. The bleed-out window (`|BLEEDOUT_FLOOR| / BLEED_RATE` = 240 ticks ≈ 8 s) is deliberately **longer than `REVIVE_TICKS`** so a teammate can win the race on a fresh down.
- **Bleed-out → death:** when effective health reaches `BLEEDOUT_FLOOR`, transition to `alive=false` and enter the normal respawn path.

### Instant-kill bypass (skip DOWNED)

A lethal hit goes **straight to dead** (skips DOWNED) when it is:

- a **headshot**, or
- an **explosive / blast** death — frag grenade, RPG, mine/claymore, or C4.

All other lethal damage (body gunfire, falling, generic) routes through DOWNED first. The bypass decision is made at damage-application time in `combat.gd` / the blast-resolution path, keyed off the existing hit-region (head vs body) and a `damage_source` tag (`BULLET` / `BLAST` / `FALL` / …).

### Finishing a downed pawn — **removed** (revised 2026-06-15)

There is **no finishing mechanic**: a DOWNED pawn is **immune to weapon damage** (see DBNO above). Neither a headshot nor continued body fire nor a blast affects an already-downed pawn — only passive bleed-out or a revive resolves it. (Matches BattleBit, where downed players take no damage; it also removed the 1 s-finish-vs-3 s-revive race that made revives impossible at fleet density.) The instant-kill bypass above still applies to the **entry** hit (a headshot/blast that would down a *standing* pawn kills outright instead). A downed pawn still cannot be revived by an enemy — only its own team.

### Self-bandage, revive

- **Self-bandage:** consumes one bandage; sets `bleed_halted = true` (stops further drain). Does **not** restore HP and does **not** self-revive. A halted-but-downed pawn waits for a teammate.
- **Revive:** an alive teammate within `REVIVE_RANGE` holds the revive action for `REVIVE_TICKS`; on completion the downed pawn returns with `alive`, `is_downed=false`, health `REVIVE_HP`. **Medic** revives in `REVIVE_TICKS / 2`. Server validates: reviver alive, in range, target DOWNED, same team. Revive **intent is latched** server-side (set by `REVIVE_ACTION(active)`, held until the revive ends) so a per-tick intent packet dropped under fleet input-starvation does not reset progress; only the reviver actually leaving `REVIVE_RANGE` interrupts (resets) the hold.
- **Visibility:** a downed pawn must be replicated to in-range teammates for them to revive it. Friendlies are **always replicated** (interest culling applies to enemies only — see Wire format); this is required for revive to work at fleet density.
- Bandages do not regenerate mid-life; replenished on spawn and via the Support ammo tool (P2).

### Ticket economy hook

DOWNED costs **no ticket**. The Conquest death-cost is deducted only at **true death** (transition to `alive=false` — bleed-out, or the instant-kill bypass on the entry hit). **A successful revive saves the ticket.** This moves the existing `ConquestState` death-cost hook from "health ≤ 0" to "pawn transitions to `alive=false`". This is the only P1 change that touches `ConquestState`; the win condition is otherwise unchanged.

### P1 constants

| Const | Value | Meaning |
|---|---|---|
| `BANDAGE_COUNT` | 3 | bandages per spawn (all classes) |
| `MEDIC_EXTRA_BANDAGES` | 2 | extra bandage charges for Medic |
| `BLEED_RATE` | 1 HP/tick | drain while DOWNED and not halted (was 2; lowered so the bleed-out window outlasts a revive) |
| `BLEEDOUT_FLOOR` | −240 HP | death threshold = 240 ticks ≈ 8 s bleed-out window (was −50; must exceed `REVIVE_TICKS`) |
| `DOWNED_CRAWL_SPEED` | 1.0 m/s | crawl speed while DOWNED |
| `REVIVE_TICKS` | 90 (3 s) | revive duration (non-medic) |
| `REVIVE_HP` | 30 | HP on revive |
| `REVIVE_RANGE` | 3.0 m | max range to begin/hold revive (was 2.0; gate-tuned up for positioning margin) |

---

## P2 — Combat depth

All gadgets are data-driven in `data/gadgets.json`, sent over the INPUT/CONTROL channels as **intent**, and resolved server-authoritatively. All blasts reuse the M4 `Grenade` ballistic + detonation model and are **friendly-fire-off** (FF-off), present-time (no lag-comp rewind for area damage), with linear falloff — identical to M4 frag grenades.

### Class gadget assignment

| Class | Gadget(s) | Weapon-slot option |
|---|---|---|
| Assault | Frag grenade (M4), Smoke grenade (M4) | — |
| Medic | **Heal tool** (RMB active / LMB throw bag); revive 2× + extra bandages are class traits | — |
| Engineer | **C4** (remote detonate); vehicle repair kit *(M5)* | **RPG** (Engineer-only) |
| Support | **Ammo tool** (RMB active / LMB throw bag) | — |
| Recon | **Claymore / mine** (proximity) | — |

Open gadget slots (Support B, Recon B) stay **empty in v1** — no fillers invented.

### Medic heal tool & Support ammo tool (two-mode, active)

Both are one tool with two fire modes; both modes server-authoritative.

- **RMB — active (fast):** server raycasts from the user's aim. If it lands on a **teammate** within `*_GIVE_RANGE` with LOS, apply healing (Medic) or ammo+bandage resupply (Support) at the **active rate** per tick while RMB is held. One target. **Unlimited but rate-limited** — no per-life pool; the cost is that the user stands exposed and aiming.
- **LMB — throw bag:** spawn a deployable bag entity at the landing point. Server tracks `{owner, pos, tick_placed, pool_remaining}`. Every teammate in `*_BAG_RADIUS` is healed/resupplied at **`*_BAG_RATE` = 25% of the active rate** per tick. Each HP (Medic) or round/charge (Support) dispensed decrements `pool_remaining`; the bag **disappears when `pool_remaining` reaches 0**. Max `MAX_*_BAGS` live thrown bags per player.

Medic heal tool tops up HP only — it does **not** revive a DOWNED pawn (revive is the separate hold-action). Support ammo refills weapon ammo **and** bandages.

For ammo, "rate" is rounds (or mag-fractions) per tick: active refills a teammate quickly; the thrown bag trickles to everyone in radius at ¼ that, drawing from the bag pool.

### C4 (Engineer)

Place on any surface (structure cell face or flat ground); sticks at placement point. Up to `MAX_C4_PLACED` active. Second gadget-use remote-detonates all owned C4 simultaneously. Server tracks `{owner, pos, cell_or_surface, tick_placed}`; detonation = blast at position (same `ids_in_radius` + pawn-sphere path as grenades, FF-off). C4 on a structure cell is removed when that cell is destroyed.

### Mine / claymore (Recon)

Place on a flat surface within `MINE_PLACE_RANGE`. Server tracks `{owner, pos, facing, tick_placed, armed_after_tick}`. Each tick, if armed and an **enemy** pawn enters `MINE_TRIGGER_RADIUS`, trigger: directional cone (claymore) or omnidirectional sphere (mine), falloff damage, FF-off. Arms after `MINE_ARMED_DELAY_TICKS`. Max `MAX_MINES_PER_PLAYER` live.

### RPG (Engineer-only)

Weapon-slot choice (replaces primary), selectable **only on Engineer loadouts** — `loadout.gd` rejects RPG selection for other classes. Server-side arc trajectory reuses the `Grenade` ballistic model. Detonates on structure/vehicle/ground contact. Area damage: structures (`BLAST_CELL_RADIUS`) + pawns (sphere, linear falloff, FF-off, present-time). `ROCKET_COOLDOWN_TICKS` between shots; carry `MAX_ROCKETS` per spawn. Anti-vehicle damage wired in M5; structure + pawn damage active now.

### Bullet penetration

Material tag `material` added per piece type in `fortifications.json`: `WOOD`, `METAL_THIN`, `CONCRETE`, `METAL_THICK`.

`combat.gd` `march()` extended: on hitting a penetrable piece, apply `weapon.damage_body × absorption` to the piece; if the piece survives (health > 0), continue the ray with `remaining_damage × transmit_factor` toward the next target. **Max 1 penetration per shot** in v1.

| Material | Penetrable | Absorption | Transmit factor |
|---|---|---|---|
| WOOD | yes | 0.40 | 0.60 |
| METAL_THIN | yes | 0.65 | 0.35 |
| CONCRETE | no | — | — |
| METAL_THICK | no | — | — |

Piece removal + bucket-delta follow the M4 Phase 2 path. **Lag-comp rewind is unchanged:** the shot still resolves against rewound enemy positions; material absorption is applied after the ray exits the structure, using current (non-rewound) remaining damage.

### Weapon attachments

Three slots per weapon — **Optic**, **Barrel**, **Underbarrel** — data-driven in `data/attachments.json`. Multipliers apply to the base weapon record at combat-resolution time, **before** hit resolution, in `combat.gd`. Loadout-time only (set at deploy screen); **no mid-match swapping**. No attachment affects lag-comp or server authority.

| Slot | Options (v1) | Stat effect |
|---|---|---|
| Optic | Iron (default), Red dot, 2×, 4× | `spread_base_deg` multiplier; zoom is client-side (M7) |
| Barrel | Standard (default), Suppressor, Muzzle brake | Suppressor: small range drop + audio (M7); Brake: recoil-pitch multiplier |
| Underbarrel | None (default), Vertical grip, Bipod | Grip: `spread_move_penalty_deg` multiplier; Bipod (prone only): spread → 0 |

`loadout.gd` gains `attachments: Dictionary` (slot → attachment ID).

### P2 constants

| Const | Value | Meaning |
|---|---|---|
| `MEDIC_GIVE_RANGE` / `AMMO_GIVE_RANGE` | 3.0 m | RMB active aim range |
| `MEDIC_ACTIVE_RATE` | 2 HP/tick (60 HP/s) | active heal; full top-up ≈1.7 s |
| `AMMO_ACTIVE_RATE` | 1 mag / 30 ticks (1 mag/s) | active resupply |
| `MEDIC_BAG_RATE` / `AMMO_BAG_RATE` | 25% of active (0.5 HP/tick · 1 mag/120 ticks) | per teammate in radius, thrown bag |
| `MEDIC_BAG_POOL` | 300 HP | total HP dispensable before the bag vanishes (≈3 full heals) |
| `AMMO_BAG_POOL` | 8 mags | total mags dispensable before the bag vanishes |
| `MEDIC_BAG_RADIUS` / `AMMO_BAG_RADIUS` | 3.0 m | thrown-bag area |
| `MAX_MEDIC_BAGS` / `MAX_AMMO_BAGS` | 1 | live thrown bags per player |
| `MINE_TRIGGER_RADIUS` | 1.5 m | proximity trigger |
| `MINE_ARMED_DELAY_TICKS` | 60 (2 s) | arm delay |
| `MINE_PLACE_RANGE` | 2.0 m | placement reach |
| `MAX_MINES_PER_PLAYER` | 2 | live mines |
| `MAX_C4_PLACED` | 2 | live C4 |
| `MAX_ROCKETS` | 2 | rockets per spawn |
| `ROCKET_COOLDOWN_TICKS` | 120 (4 s) | min ticks between RPG shots |

---

## P3 — Movement

P3 is the Movement phase: **ladder climbing**, **vaulting**, and **drop-shoot prevention**. All three are server-authoritative; the movement *rules* live in `shared/sim/` so a future (M7) rendered client can predict them, but the headless bot fleet validates the **server-authoritative** path only — no new client prediction is built this phase (consistent with M7 deferral elsewhere). This section is the build contract; it refines the milestone-doc P3 scope and the brainstorm decisions of 2026-06-16.

### World-model context (why the geometry is new)

The world is a **flat `y=0` plane**. Pawns only gain height via jump/gravity (`pawn.gd::step` floors `pos.y` at 0); they never stand on a structure roof, and movement collision (`StructureStore.resolve_movement`) is **coarse ground-cell** sliding that blocks *any* occupied ground cell regardless of the piece's height. So before P3 there is nothing to climb and nothing to vault. P3 introduces the minimum geometry for both: **static map ladders + a raised ledge** (ladder climbing), and **height-based vault** over half-height blockers plus one static low obstacle. No structure-system or destruction changes.

### Ladder climbing

**Geometry — `MapDef` (data-driven, static):** two new optional arrays in the map JSON, parsed + validated by `map_def.gd`:

- `ladders: [{bottom:[x,y,z], top:[x,y,z], radius:float}]` — a vertical climb volume. The climb axis is the segment `bottom`→`top`; a pawn is *captured* when its (x,z) is within `radius` of the (x,z) ladder line and its y is within `[bottom.y, top.y]`.
- `platforms: [{min:[x,y,z], max:[x,y,z]}]` — static walkable AABBs the ladders lead to (the ledge/elevated surface). This is the one **new movement capability**: a pawn lands on the highest platform top beneath its (x,z) footprint instead of falling to `y=0`. O(N × few platforms)/tick.

The proving-grounds map gets **one ladder + ledge placed on the natural bot route** (between a base and point C) so traversal happens organically at fleet density — geometry on the traffic path, not positioning luck (carried lesson from P2's claymore).

**Mechanic (server-authoritative):** entering a ladder's capture volume **auto-engages CLIMB mode** (no dedicated button — see below). While climbing: vertical velocity is driven by `move_y` (forward = up, back = down) at `LADDER_CLIMB_SPEED`, **gravity is off**, and horizontal position is clamped to the ladder line with limited strafe (`LADDER_STRAFE_SPEED`). The pawn exits CLIMB and **snaps to the top/bottom anchor** when it reaches an end of the segment, or when it steps off the volume at a valid dismount. `pawn.gd` gains a `climbing` flag and branches to a `_step_climb` path (mirrors `_step_downed`); `sim_loop.gd` decides entry/exit because it holds the map geometry (a new `map_geom` handle) and the tick.

**No new input button (ratified deviation from the milestone text).** The milestone doc says "while `CLIMB` held," but the input `buttons` field is a **full `u8`** (JUMP=1 … RELOAD=128, all 8 bits used). Rather than widen the wire to `u16` for a key a headless fleet does not have, climb **auto-engages** on volume entry and `move_y` drives up/down. This matches the auto-trigger philosophy P3 already uses for vaulting; the M7 rendered client maps a key to forward-on-ladder. **No change to `InputCommand`.**

### Vaulting

**Auto-triggered, height-generic (BattleBit rule).** When a **standing, moving** pawn's intended move is blocked by a blocker whose **top is ≤ `VAULT_MAX_HEIGHT`** (~1.2 m) with clearance above and landing room on the far side, the pawn runs a scripted up-and-over arc over `VAULT_TICKS`; normal input movement is suspended for the duration. **No vault while crouched, prone, or downed.** `pawn.gd` gains a `vaulting` flag + arc-progress fields; `sim_loop.gd` advances the arc each tick. Detection keys off the **blocker's top y**, not a piece flag, so any future low piece (window sill, half-wall remnant, rubble) vaults for free with no vault-code change.

**Vaultable surfaces (both consulted by `vault.gd`):**

- **Half-height structure pieces** — `is_half` pieces are 1.0 m tall (`0.5 × CELL_SIZE`, CELL_SIZE=2.0); sandbags qualify, full walls (2.0 m) do not. Bots already build sandbags in P2, so these occur in live matches.
- **One static low obstacle** added to the map (a `vault_obstacles: [{min,max}]` AABB) **on the bot route**, guaranteeing deterministic vault events at the gate independent of where bots happen to build (carried lesson from P2's claymore).

> **Explicit content non-scope (ratified 2026-06-16):** the vault *rule* is height-generic, but the *content* it can act on this phase is only half-height pieces + the static obstacle. Blockfire has **no window/door piece type** and destruction **removes a wall entirely** at 0 HP (no low stub). True "vault a half-destroyed wall / through a window" needs new content (a window/low-wall piece, or destruction leaving a low remnant) — deferred to a later content pass (M5/M7); it will vault for free when it lands.

### Drop-shoot prevention

`sim_loop.gd` records `pawn.last_stance_change_tick = tick` whenever a pawn's stance changes (compare stance across the step; it owns the tick). The server fire path (`_resolve_fires`) blocks the shot when `shooter.stance == PRONE and tick − last_stance_change_tick < PRONE_TRANSITION_TICKS`. This penalizes the first `PRONE_TRANSITION_TICKS` of **any** prone entry (stand→prone and crouch→prone), eliminating the drop-shoot exploit; **stand→crouch is naturally exempt** (current stance isn't PRONE), per the milestone's smaller-advantage/smaller-penalty call. **Gate criterion is the unit test** (a pawn that goes prone while firing has the in-transition shot rejected), not live fleet behavior; a bot may optionally exercise it live (report-only).

**Non-scope:** no sliding, no parachutes, no swimming / water movement (all design decisions).

### P3 constants (initial; gate-tuned)

| Const | Value | Meaning |
|---|---|---|
| `LADDER_CLIMB_SPEED` | 3.0 m/s | vertical climb speed (driven by `move_y` sign) |
| `LADDER_STRAFE_SPEED` | 1.0 m/s | limited horizontal speed while on a ladder |
| `LADDER_CAPTURE_RADIUS` | 0.6 m | (x,z) capture distance from the ladder line |
| `VAULT_TICKS` | 8 | ticks to complete a vault arc (~0.27 s) |
| `VAULT_MAX_HEIGHT` | 1.2 m | max blocker top height that is vaultable (half piece = 1.0 m qualifies) |
| `PRONE_TRANSITION_TICKS` | 10 | fire block after entering prone (~0.33 s) |

### P3 wire format

- **No new input message** — climb and vault auto-engage from existing `move_x/move_y`; `InputCommand` is unchanged.
- **No new reliable CONTROL message** — climb/vault are derived server-side from input + position; drop-shoot is server-internal.
- **Snapshot:** `EntityState` packs a `climbing` and a `vaulting` flag (≤1 byte/pawn total, for M7 client animation). No new per-tick streams. Bandwidth impact negligible.

### P3 module layout (concrete)

```
shared/sim/
  ladder.gd     NEW   pure helpers: capture test, climb-step position, platform-floor lookup,
                      dismount/anchor snap
  vault.gd      NEW   pure helpers: height-generic vaultable detection (top ≤ VAULT_MAX_HEIGHT,
                      clearance + landing room), vault arc position over VAULT_TICKS
  pawn.gd       (mod) climbing/vaulting flags + arc progress; last_stance_change_tick;
                      _step_climb / _step_vault branches (mirror _step_downed)
  sim_loop.gd   (mod) map_geom handle; climb entry/exit, vault arc, platform landing,
                      stance-change tick recording
  map_def.gd    (mod) parse + validate ladders / platforms / vault_obstacles
  entity_state.gd (mod) climbing + vaulting replication flags
server/server_main.gd  (mod) drop-shoot fire gate in _resolve_fires; build + pass map_geom to
                              SimLoop; telemetry counters climbs / vaults
maps/conquest_proving_grounds.json (mod) one ladder + ledge + one static low vault obstacle on
                                         the bot route to point C
bots/bot_driver.gd     (mod) navigate onto the ladder when the objective lies across it
                              (steer + drive move_y up); optional prone-fire exerciser (report-only)
ci/m4.5_p3_test.sh     NEW   laptop-48 smoke + 128-bot fleet assertions (climbs≥1, vaults≥1,
                              drop-shoot unit-tested, tick + bw budget, Conquest winner)
tests/
  ladder_test.gd  NEW  capture test, climb-step (no gravity, move_y sign), platform floor, anchor snap
  vault_test.gd   NEW  height-generic detection (1.0 m vaults, 2.0 m blocks), crouch/prone block,
                       arc completes in VAULT_TICKS
  (extend pawn/server tests) last_stance_change_tick recording; drop-shoot fire-gate rejection
```

---

## Module layout (extends M4)

```
shared/sim/
  pawn.gd        (mod) DOWNED state, is_downed, bleed_health, bandage_count, bleed_halted,
                       last_stance_change_tick; crawl speed when DOWNED
  combat.gd      (mod) penetration in march(); instant-kill bypass (headshot/blast → dead);
                       finishing (headshot kills downed, body fire accelerates bleed);
                       drop-shoot fire gate; apply attachment multipliers pre-resolution
  structure.gd   (mod) material tag lookup from catalog (penetration path)
  gadget.gd      NEW   gadget type enum + pure helpers: C4 / mine / medic-tool / ammo-tool / RPG
                       record structs; placement validation; proximity queries; detonation blast;
                       active-give raycast resolution; bag pool decrement
  grenade.gd     (mod) type field (FRAG / SMOKE) — from M4
  weapon.gd      (mod) attachment slot system; apply_attachment_multipliers()
  loadout.gd     (mod) attachments dict per weapon slot; RPG gated to Engineer class
  revive.gd      NEW   DBNO/revive/bandage pure state machine (down → bleed → halt → revive/death)
  ladder.gd      NEW   ladder geometry detection + climb movement pure helpers
  vault.gd       NEW   vaultable obstacle detection + arc position helpers
shared/net/
  protocol.gd    (mod) Msg.GADGET_ACTION (C4 detonate / mine place / RPG fire / bag throw /
                       active-give), Msg.REVIVE_ACTION, Msg.SELF_BANDAGE; snapshot carries
                       DOWNED state; LADDER_STATE in pawn packed byte
                       (NO GRAB_BODY/RELEASE_BODY/carrier_id — body drag deferred to M7)
data/
  gadgets.json      NEW   C4, mine/claymore, medic-tool, ammo-tool, RPG definitions
  attachments.json  NEW   attachment definitions + stat multipliers per slot
  fortifications.json (mod) material field per piece type
server/server_main.gd  (mod) DBNO/bleed/revive tick; gadget entity tick (C4, mines, bags, RPG arcs);
                              active-give resolution; drop-shoot gate; penetration in fire path;
                              ladder/vault validation; ticket hook at true-death; telemetry
bots/bot_driver.gd     (mod) revive downed teammates; medic/ammo active-give to wounded/low teammates
                              + throw bags; RPG (Engineer bots) at heavy cover; place mines/C4;
                              navigate ladders; trigger vaults
ci/m4.5_combat_test.sh NEW   per-phase fleet gate assertions (see Gates)
```

---

## Wire format

- **New reliable CONTROL messages** (low-frequency, not per-tick): `GADGET_ACTION{type, params}` (C4 place/detonate, mine place, RPG fire, bag throw, active-give start/stop), `REVIVE_ACTION{target_id, start/stop}`, `SELF_BANDAGE`.
- **Snapshot additions:** DOWNED state packed into the existing pawn state byte(s) (~1 bit/flag, ≤1 byte/pawn total with ladder state); no new per-pawn fields beyond flags. Gadget entities (C4, mines, bags) are **not** streamed per-tick — their deploy/detonate/exhaust events are the reliable CONTROL messages above; clients derive presence from events (rendering in M7).
- **Bandwidth:** DOWNED + ladder flags ≤1 byte/pawn on the snapshot. No per-tick gadget-entity stream.
- **Interest culling is enemies-only (revised 2026-06-15):** every teammate in interest range is **always replicated** (no wallhack reason to hide friendlies, and a client must see downed squadmates to revive them); only enemies are capped (`MAX_ENEMY_SNAPSHOT` nearest). The prior hard count cap (`MAX_SNAPSHOT_ENTITIES`, enemies-first) hid downed teammates at fleet density and broke revive. Cost measured on the 128-bot fleet: snap 12.3→16.4 ms/tick, aggregate 8.8→22.6 Mbit/s (~176 kbit/s per client) — within budget, tick peak 22 ms < 33.3. **Note:** true 256-player scale needs rate/precision **LOD on distant entities** (replicate everyone, downgrade far ones) rather than this keep-all approach — tracked as separate netcode work, out of P1 scope.

---

## Budgets

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), stacking onto M4's ~29.5 ms clean peak. New per-tick work: DBNO/bleed O(N downed), gadget entity tick O(deployed entities), active-give O(N givers), mine proximity O(mines × pawns in range), penetration O(1) extra march step, drop-shoot gate O(1) per fire. **Headroom is thin — profile per phase.**
- **Degradation knobs:** `MAX_STRUCTURE_DELTAS_PER_TICK` (M4), gadget caps (`MAX_MINES_PER_PLAYER`, `MAX_C4_PLACED`, `MAX_*_BAGS`), `MAX_BOT_GRENADES` / `MAX_BOT_BUILDS` (bot-side throttles), `BLAST_*_RADIUS`.

---

## Gates (per phase; 128-bot 2-team fleet, all features enabled)

Run on the unraid W-2275 Docker fleet (`docker/`, server pinned to isolated cores). Each phase closes only with recorded evidence (AGENTS.md §6).

**P1 — Survivability**

- DOWNED events in telemetry; bot revives a downed teammate **before** bleed-out (revive-completion events).
- Ticket saved on revive (true-death-only ticket deduction observable: downed-then-revived pawns do not decrement tickets).
- Headshot / explosive deaths bypass DOWNED (telemetry distinguishes instant-kill vs downed).
- Tick + bandwidth budget held; Conquest loop still reaches a winner.

**P2 — Combat depth**

- C4 detonation events; mine-kill events; RPG detonation + structure damage + pawn kills; medic active-heal + thrown-bag-heal events; ammo active-resupply + thrown-bag events; bag-exhausted (disappear) events.
- RPG selectable only by Engineer bots (loadout rejection unit-tested).
- Penetration unit-tested (absorption/transmit math, 1-pen cap, post-exit damage).
- Attachment multipliers unit-tested; RPG-on-non-Engineer rejected.
- Tick + bandwidth budget held; Conquest winner reached.

**P3 — Movement**

- Bot traversal of test geometry containing ladders and vaultable obstacles (climb + vault events).
- Drop-shoot rejection unit-tested: a pawn that goes prone while firing has the in-transition shot rejected by the server.
- Tick + bandwidth budget held; Conquest winner reached.

---

## Test plan

TDD per task (AGENTS.md §2; tests in `tests/*_test.gd` extending `TestCase`). Unit coverage, by phase:

- **P1:** `revive.gd` state machine (down → bleed → halt-on-bandage → revive vs bleed-out → death); instant-kill bypass routing (headshot/blast vs body); finishing (headshot kills downed, body fire accelerates bleed); ticket hook fires only at true death.
- **P2:** active-give raycast (teammate-only, range, LOS); bag pool decrement + disappear-at-0; 25%-rate relation; C4 place/detonate/remove-on-cell-destroy; mine arm-delay + enemy-only trigger; RPG Engineer-only loadout gate; penetration absorption/transmit + 1-pen cap + lag-comp invariance; attachment multiplier application.
- **P3:** ladder climb helper (anchor snap, no-gravity mode); vault arc + crouch/prone block; drop-shoot fire gate.
- **Integration:** the per-phase fleet gate is the real integration test.

## Open / deferred decisions

- All constants carry seeded initial values; final numbers are confirmed during the per-phase gate-tuning pass.
- Smoke LOS, scope zoom, suppressor audio, attachment visuals, body-drag rendering — all M7.
- Vehicle repair kit + RPG anti-vehicle damage — M5.
