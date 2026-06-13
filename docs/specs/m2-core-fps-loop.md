# Spec: M2 Core FPS Loop

**Status:** approved-pending-review · **Date:** 2026-06-13 · **Milestone:** [M2](../milestones/M2-core-fps-loop.md)

Builds the recognizable shooter loop on top of the M1 authoritative netcode core: full movement, hit-scan gunplay with lag-compensated hit registration, health/death/respawn, minimal classes, teams, and combat-capable bots. Stays server-authoritative; all gameplay rules live in `shared/` so client prediction can't diverge from server authority (AGENTS.md §7).

## Design decisions (ratified)

| Decision | Choice | Rationale |
|---|---|---|
| Lag compensation | **Client fire-tick rewind, clamped + server-validated** | Fairest to the shooter; server validates the claimed view tick is in-bounds (anti-cheat hook). |
| Hitboxes | **Two-part: head sphere + body capsule**, headshot multiplier | Cheap to rewind at 128p; delivers the core headshot feel. |
| Weapons | **Hit-scan only** (recoil/spread/reload/ammo) | Proves the combat + hit-reg loop with least scope; projectiles deferred. |
| Movement | **Full set**: walk/sprint/crouch/prone/lean/jump/stamina | Complete BattleBit-style movement. |
| Teams / friendly fire | **2 teams, FF OFF** | Bots target only enemies; same-team hits ignored. |
| Spread / recoil | **Deterministic, server-authoritative** (seeded by shooter+tick+shot index) | Prediction-consistent and cheat-resistant: server reconstructs the ray from input look angles, never trusts a client-supplied ray. |

## Budgets (M2 gate pass/fail)

- **Server tick:** mean step **< 33.3 ms** at 128 bots (30 Hz held), including combat + lag-comp rewinds.
- Bandwidth budgets unchanged from M1 (≤ ~64 KB/s mean per client target; < ~250 Mbit/s aggregate).
- **Functional gate:** in a 128-bot run, bots move and shoot **enemies**, **kills register** (KILL events + telemetry), and the server stays stable for the run.

---

## Module layout (extends M1)

```
shared/sim/
  pawn.gd          (modify) + y/jump/gravity, velocity, pitch, stance, lean, stamina, health, alive, team
  stance.gd        NEW  stance enum + per-stance params (speed, body/eye height, hitbox dims)
  weapon.gd        NEW  data-driven weapon defs + registry (hit-scan stats, recoil/spread)
  combat.gd        NEW  deterministic ray reconstruction + damage resolution (shared rules)
  hitbox.gd        NEW  head sphere + body capsule from a pawn state; ray-intersection tests
  loadout.gd       NEW  class enum -> weapon mapping (minimal)
  sim_loop.gd      (modify) integrate movement (stances/jump/stamina); advance fire/reload timers
shared/net/
  protocol.gd      (modify) + Msg.KILL (reliable control event)
  input_command.gd (modify) + expanded button bitmask + view_server_tick field
  snapshot.gd      (modify) + replicate pitch, packed state byte (stance/lean/team/alive), health
  entity_state.gd  (modify) + pitch, stance, lean, team, alive, health
server/server_main.gd  (modify) per-pawn lag-comp history; fire resolution; death/respawn; KILL events; combat telemetry
server/lag_comp.gd     NEW  per-pawn history ring + rewind(server_tick) -> reconstructed states
client/client_main.gd  (modify) send buttons/look/view tick; predict ammo/fire-timer; apply health/alive
client/prediction.gd   (modify) predict full movement (stances/jump/stamina)
bots/bot_driver.gd     (modify) combat AI: acquire enemy, aim, fire, respawn
data/weapons/*.tres or weapon table in weapon.gd   NEW  2-3 weapon defs
```

---

## Movement (`pawn.gd`, `stance.gd`)

Pawn state grows to: `pos: Vector3` (now with **y** for jumping; ground plane y=0), `velocity: Vector3`, `yaw`, `pitch` (clamped ±85°), `stance` (STAND/CROUCH/PRONE), `lean` (NONE/LEFT/RIGHT), `stamina` (0–100), `health`, `alive`, `team`.

Per-stance params in `stance.gd`:

| stance | move speed | eye height | body capsule (h × r) | head sphere (center y, r) |
|---|---|---|---|---|
| STAND | 6.0 m/s | 1.6 | 1.8 × 0.35 | 1.70, 0.15 |
| CROUCH | 3.0 m/s | 1.1 | 1.2 × 0.35 | 1.15, 0.15 |
| PRONE | 1.2 m/s | 0.45 | 0.5 × 0.35 | 0.45, 0.15 |

- **Sprint:** ×1.6 speed (STAND only), drains stamina 15/s, blocks firing.
- **Stamina:** regen 12/s after 1 s without sprint/jump; sprint/jump gated on stamina > 0.
- **Jump:** impulse `v0 = 4.5 m/s` when grounded + stamina cost 10; gravity 14 m/s²; land at y=0 (grounded).
- **Lean:** lateral eye/ray origin offset (±0.4 m) for peeking; does not move the body capsule in M2 (offset applies to the shot origin + camera only).
- Movement remains **world-space** planar (yaw-relative strafe optional later); kinematic integration in the shared sim.

**Replicated additions:** `pitch`, `stance`, `lean`, `team`, `alive`, `health` (see Wire protocol). These are needed for remote rendering and for reconstructing hitboxes during lag-comp rewind.

---

## Gunplay (`weapon.gd`, `combat.gd`, `hitbox.gd`, `loadout.gd`)

**Weapons are data-driven.** Fields: `damage_body`, `headshot_mult`, `rpm`, `mag_size`, `reload_secs`, `recoil_pattern` (per-shot pitch climb + horizontal jitter scale), `spread_base_deg`, `spread_bloom_deg` (per-shot, decays), `spread_move_penalty_deg`, `range_m`, `falloff` (M2: flat damage to `range_m`, 0 beyond). v2 ships 2–3: e.g. **AR** (25 dmg, ×2.0 head, 600 rpm, 30 mag, 2.2 s), **SMG** (18 dmg, ×1.8, 900 rpm, 35 mag, 2.0 s), **DMR** (45 dmg, ×2.0, 260 rpm, 20 mag, 2.6 s).

**Deterministic ray (the cheat-resistant core):** the only fire data the client sends is the look angles (`yaw`,`pitch`, already in input), the `FIRE` bit, and `view_server_tick`. The server computes the shot ray itself:
```
seed       = hash(shooter_id, fire_tick, shot_index)
spread_deg = weapon.spread_base + bloom(shot_index) + move_penalty(shooter)
ray_dir    = rotate(look_dir(yaw,pitch), recoil(weapon, shot_index), jitter(seed, spread_deg))
ray_origin = eye_position(pawn) + lean_offset
```
`shot_index` = number of consecutive shots since the trigger was first pulled (server-tracked per client). Both client and server can compute this identically (used later for client-side effect prediction); **only the server resolves hits**, and it never trusts a client-provided ray.

**Fire control (server-authoritative):** enforce min inter-shot interval `= 60/rpm`; require `ammo > 0`, not reloading, not sprinting, `alive`. On a valid shot: decrement ammo, advance `shot_index`, run hit resolution. `RELOAD` button (or empty mag) starts a `reload_secs` timer that refills the mag. Client **predicts** ammo count / fire-timer / reload (for responsiveness) but never damage.

---

## Lag compensation (`server/lag_comp.gd`)

- Each server tick, after the sim step, record per-pawn `{pos, yaw, pitch, stance, lean, alive}` into a **history ring** of `HISTORY = 32` ticks (~1.06 s), keyed by `server_tick`.
- The fire command carries **`view_server_tick`** — the server tick the client's interpolation was rendering at fire time (client knows this: it renders ~100 ms behind using server snapshots). 
- Server rewind target tick: `rewind = clamp(view_server_tick, now - MAX_REWIND, now)` with `MAX_REWIND = 12` ticks (~400 ms). If the claimed tick is outside `[now-HISTORY, now]`, clamp and flag in telemetry (anti-cheat hook).
- **Broad phase → narrow phase:** candidate targets = **enemy-team**, `alive`, in the shooter's interest set, within `weapon.range_m`, and within an angular cone of the ray. Rewind only those to `rewind`, rebuild their hitboxes, run precise ray tests, take the nearest hit. This keeps per-shot cost bounded under 128-bot load.

---

## Hitboxes (`hitbox.gd`)

From a (possibly rewound) pawn state, build:
- **Body:** vertical capsule, segment `[feet .. body_height]` at `pos`, radius per stance.
- **Head:** sphere at `(pos + head_center_y)`, radius per stance.

Ray test both (ray-capsule, ray-sphere); nearest intersection within `range_m` wins. A head hit applies `headshot_mult`. Lean shifts the shooter's ray origin, not the target hitboxes.

---

## Health / death / respawn

- `health` starts 100. Damage applied server-side (FF off → same-team damage ignored).
- `health ≤ 0` → `alive = false`; emit **KILL** event; pawn stops simulating movement/fire.
- **Minimal respawn (M2):** after `RESPAWN_DELAY = 5 s`, respawn at a random point in the team's spawn half with full health, `alive = true`. (Full deploy screen + squad spawn is M3.)

---

## Teams & spawning

- **2 teams** (0, 1). New pawn assigned to the **smaller** team (balanced). `team` is replicated.
- **Spawn halves:** team 0 spawns in `x < 0`, team 1 in `x > 0` (random within the half, full world z-range), giving natural initial separation and engagement lanes.
- **Friendly fire OFF:** damage resolution returns no damage when `shooter.team == target.team`. Bot AI never targets same-team pawns.

---

## Classes (`loadout.gd`, minimal)

Class enum: ASSAULT, MEDIC, ENGINEER, SUPPORT, RECON. For M2 a class **only selects its loadout weapon** (e.g. Assault→AR, Engineer→SMG, Recon→DMR; Medic/Support→AR for now). Gadgets/abilities are deferred. Bots pick a class at spawn.

---

## Wire protocol changes

**INPUT (client→server)** — extend the existing frame:
- `buttons` (u8 bitmask, already present): bit0 JUMP, bit1 CROUCH, bit2 PRONE, bit3 SPRINT, bit4 LEAN_L, bit5 LEAN_R, bit6 FIRE, bit7 RELOAD.
- **add** `view_server_tick` (u32) — for lag-comp rewind. (`yaw`/`pitch` already sent in M1.)

**SNAPSHOT / EntityState** — replicate the new visible state. `entity_state` gains `pitch`, `stance`, `lean`, `team`, `alive`, `health`. On the wire, pack `stance(2b) | lean(2b) | team(1b) | alive(1b)` into one **state byte**; `pitch` as u16; `health` as u8. Extend `field_mask` with `F_PITCH`, `F_STATE`, `F_HEALTH` (still ≤ 8 bits total: F_POS_X/Y/Z, F_YAW, F_PITCH, F_STATE, F_HEALTH = 7 fields).

**New event — `Msg.KILL` (reliable, CONTROL channel, server→client):** `victim_id u32, killer_id u32, weapon_id u8, headshot u8`. Feeds killfeed (M7) and kill telemetry now.

---

## Bot combat AI (`bots/bot_driver.gd`)

Each bot, per tick, using its received interest view:
1. **Acquire:** nearest **enemy-team**, `alive` pawn within range and rough forward LoS; keep target until lost/dead.
2. **Aim:** set `yaw`/`pitch` toward the target with a small error term (so aim isn't pixel-perfect); when no target, keep random-walk heading.
3. **Fire:** press `FIRE` when aim error < tolerance and target alive; respect ammo (press `RELOAD` when empty).
4. **Move:** advance toward the current target (or nearest enemy / map center) instead of pure random walk.
5. **Respawn:** when dead, idle until respawned, then resume.

Bots set `view_server_tick` from the latest snapshot seq's server tick they hold (they already track `last_seq`; extend to also store the snapshot's `server_tick`).

---

## Telemetry additions

Extend the per-second server log with: `kills`, `shots`, `hits`, `hit_rate`, `alive`, and `rewind_clamped` (claims outside the window). Confirms the functional gate and surfaces combat cost under load.

---

## Data flow — a shot, end to end

```
CLIENT/BOT                                  SERVER (authoritative)
collect input (look + FIRE + view_tick)
send INPUT(ch2) ─────────────────────────▶ buffer; on this client's tick:
  predict: ammo--, fire-timer, effects        if FIRE & ready & ammo>0 & !sprint & alive:
                                                 shot_index++
                                                 ray = reconstruct(look, recoil[shot_index], spread[seed])
                                                 rewind = clamp(view_server_tick, now-MAX_REWIND, now)
                                                 cand = enemy ∩ alive ∩ interest ∩ range ∩ cone
                                                 rewind cand -> hitboxes -> nearest ray hit
                                                 if hit: dmg = body/head * falloff; FF off skips same-team
                                                   health-=dmg; if dead: alive=false; KILL event; schedule respawn
                                                 ammo--
   apply SNAPSHOT (health/alive/stance...) ◀── (state replicated as usual)
   apply KILL event (killfeed/telemetry) ◀──── reliable on CONTROL
```

---

## Error handling / edge cases

| Case | Handling |
|---|---|
| `view_server_tick` outside history window | Clamp to `[now-MAX_REWIND, now]`; increment `rewind_clamped` telemetry. |
| Fire while reloading / sprinting / dead / empty | Server rejects the shot (no ammo decrement, no ray). |
| Target dies between rewind and resolution | Rewound state says `alive` at the rewind tick → hit still counts (lag-comp correctness); but a pawn already dead at `rewind` is not a candidate. |
| Same-team hit (FF off) | Resolution returns 0 damage; ray still consumes the shot. |
| Pawn falls through / NaN | Clamp y≥0 and positions to world bounds (existing M1 clamp extended to y). |
| Respawn while interest-culled | Normal snapshot ENTER/keyframe path handles re-appearance (M1). |

---

## Testing

**Unit (headless `TestCase`):**
- `stance` params + movement: jump apex/landing, gravity, per-stance speeds, sprint stamina drain/regen, stamina gating.
- `hitbox`: ray-sphere and ray-capsule hits/misses at known geometry; head vs body nearest-hit selection.
- `combat`: deterministic ray reproducible for same `(shooter,tick,shot_index)`; damage math (body vs headshot mult); FF-off returns 0 for same team; range falloff cutoff.
- `weapon`: fire-rate interval, mag/reload state machine.
- `lag_comp`: history ring records/evicts; `rewind(tick)` returns the recorded state; clamp behavior at window edges.
- snapshot round-trip with the new packed state byte + pitch + health.

**Integration / gate:** `ci/m2_load_test.sh` — server + 128 bots split across 2 teams for ~30 s; assert mean tick < 33.3 ms AND `kills > 0` (bots are actually killing each other), and stable run (no crash, alive count oscillates as expected).

---

## Out of scope for M2 (explicit)

Projectiles / bullet drop; gadgets & class abilities; full deploy screen & squad spawn (M3); real art, animation, ADS/scopes, recoil camera visuals; HUD/killfeed UI (data only in M2); destructible cover (M4). Movement stays world-space planar (no yaw-relative strafe required).
