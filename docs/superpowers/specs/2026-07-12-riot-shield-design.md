# M19-P5 — Riot Shield (Support gadget) — design

*2026-07-12. Author: claude (autonomous session). Reserves `Protocol.VERSION` **10 → 11**.*

The Riot Shield is the second-to-last M19 "heavy gadget" (only Grapple remains after this).
It is a **carried, directional bullet-block**: a Support player raises a bulletproof shield that
absorbs small-arms fire from a frontal arc into a finite shield-HP pool, at the cost of movement
speed and the use of their primary weapon. The counterplay — identical in spirit to the LMG Nest —
is **flank the arc, or blow it up**: bullets from the sides/rear, explosives, melee, and back-stabs
all bypass the shield entirely.

This slots the last built option into the Support gadget roster (`[AMMO, RIOT_SHIELD, LMG_NEST]`),
un-greying it in the class-select screen. It is **infantry combat content** (AGENTS.md §12 priority),
sim-provable deterministically (§10), with a minimal wire footprint.

## A. Design tenets (grounded in BattleBit + the existing spec §D)

- **New mechanic = carried directional cover.** Not a deployed structure (that's the Nest) — the
  shield moves *with* the player.
- **Server-authoritative damage & shield HP.** Health is never client-predicted; the directional
  block and the shield-HP pool live entirely server-side, dropped into `_apply_pawn_damage`.
- **Client-predicted movement/fire lockout.** The *cost* of raising the shield (slower move, no
  primary fire, no sprint) is a shared-`Pawn.step` rule driven by an input bit, so client prediction
  and server authority can't diverge (§7). Rule logic stays in `shared/`.
- **Flank-or-blow counterplay.** Frontal small-arms only. Everything else bypasses.

## B. State model — a held input bit, not a toggle-in-sim

The shield is **up while an input button is held** (`InputCommand.BTN_SHIELD = 1024`, bit 10 — the
first free button bit). This is the simplest correct model for prediction: the flag rides every
input frame, there is no toggle-state to desync, and the move-speed penalty predicts exactly.

- **Hold-vs-toggle is a pure client-input-mapping concern.** The client may implement a *toggle*
  (press once to keep the bit latched until pressed again) locally with zero sim/wire impact — the
  sim contract is only "is `BTN_SHIELD` set this frame". We ship the toggle UX on the client
  (ergonomic for a shield you hold up while advancing) but it produces the same held bit.
- **Gated server-side + client-side on `gadget == GADGET_RIOT_SHIELD`.** The bit is ignored for any
  other loadout, so a stale/forged bit from a non-shield player does nothing.
- **Effective `shield_up`** (a derived per-tick boolean, not stored/replicated) =
  `(buttons & BTN_SHIELD) and gadget_is_shield and not broken and alive and not downed`.

## C. Shared movement/fire rule (`shared/sim/pawn.gd`)

While `shield_up`:
- **Move speed ×`SHIELD_SPEED_MULT`** (~0.7) — folds into the existing `speed` product on
  `pawn.gd:104-106` alongside `Armor.speed_mult`/`STIM_SPEED_MULT`. Predicted identically on both sides.
- **Sprint blocked** — `sprinting` is forced false (you can't sprint holding a shield).
- **Primary fire blocked** — the fire path (server `server/fire.gd`, client `WeaponPredictor`) treats
  `BTN_FIRE` as absent while `shield_up`, so no phantom-shot HUD drift.

`Pawn` needs the equipped-gadget id available to `step` (to gate the bit). The pawn already carries a
`gadget`/loadout-derived field from the P1 framework; `step` reads it (or `cmd["gadget_is_shield"]`
is injected server-side + client-side the same way `stimmed` is, if threading the gadget id into
`Pawn` is cleaner — decided at plan time by whichever the P1 wiring already exposes).

## D. Server damage block (`server/server_main.gd::_apply_pawn_damage`) + shield HP

A new pure module **`shared/sim/riot_shield.gd`** owns the geometry + HP arithmetic so both the
damage path and tests share one implementation:

- `blocks(victim_facing, bearing_to_source) -> bool` — true when the source bearing is within
  **±`SHIELD_ARC_DEG`** (half-angle, ~75° → 150° frontal cover) of the victim's facing yaw. Reuses
  the same `atan2(dx,dz)` convention as `DamageDir.bearing`.
- `is_small_arms(source, weapon_id) -> bool` — bullets only (`Revive.Source.BULLET`, non-back-stab).
  Explosive/blast/melee/fall/back-stab return false → bypass.

In `_apply_pawn_damage`, **before** the armor/HP reduction, if the victim has `shield_up`, the source
`is_small_arms`, and `blocks(victim.facing_yaw, bearing)`:
1. Deduct `dmg` from `victim.shield_hp` (server-authoritative pool).
2. If `shield_hp` stays > 0 → **fully absorb**: no health loss, no bleed trigger, no in-combat regen
   reset beyond the normal "took fire" flag; still refresh `combat_until_tick` and `shield_last_hit_tick`.
3. If the hit **depletes** the pool → the overflow (`dmg - remaining_hp`) is *not* carried into health
   (a clean break; the shield ate the shot that broke it). Set `shield_broken_until_tick` and force
   the shield down. Subsequent hits this window pass through normally.

`bearing` is already computed in `_apply_pawn_damage` (`DamageDir.bearing(victim.pos, src.pos)`) for
the damage-direction HUD, so no extra math per hit for non-shielded victims (guarded by the
`shield_up` fast-out first).

### Shield HP lifecycle (server-owned, deterministic)
| Const | Value (initial; gate/feel-tunable) | Meaning |
|---|---|---|
| `SHIELD_HP` | 300 | full shield pool (BattleBit-ballpark heavy frontal block) |
| `SHIELD_ARC_DEG` | 75 | half-angle of the protected frontal arc (150° cover) |
| `SHIELD_SPEED_MULT` | 0.7 | move-speed multiplier while shield up |
| `SHIELD_REGEN_DELAY_TICKS` | ~90 (3 s) | no-hit delay before the pool regenerates |
| `SHIELD_REGEN_RATE` | ~60 hp/s | pool refill rate once regen starts |
| `SHIELD_BREAK_TICKS` | ~150 (5 s) | forced-down lockout after a full break |

- **Regen** (`ServerSupport.step_shields` or a step in the tick loop): if `_sim.tick - shield_last_hit_tick >= SHIELD_REGEN_DELAY_TICKS` and not broken, refill toward `SHIELD_HP`.
- **Break**: on depletion, `shield_broken_until_tick = tick + SHIELD_BREAK_TICKS`; `shield_up` cannot
  become true until that passes; at unlock, `shield_hp` is restored to full (single clean re-arm).
- **Respawn/deploy/loadout reset**: `shield_hp = SHIELD_HP`, `shield_broken_until_tick = 0` (folded
  into the existing respawn reset block in `_handle_respawns`).

## E. Wire (`shared/net/protocol.gd`, VERSION 10 → 11)

Minimal — no new message, no SNAPSHOT growth:
- **`InputCommand.BTN_SHIELD = 1024`** (bit 10). No frame-size change (buttons is already a u16).
- **`SELF_STATE` gains a trailing `u8 shield_hp_frac`** (0–255 = shield pool fraction) for the owner's
  HUD, appended after the M19-P4 mount tail — same pattern as `reserve`/`stim_charges`. Zero when the
  gadget isn't a shield.
- **VERSION → 11** (button-bit meaning + SELF_STATE byte). Update the wire-registry note (next free
  msg id stays 51; next GA sub-action stays 13 — none used here).

**Deliberately deferred to a visual follow-up (project norm §10, like stim/bleed feel):**
replicating "other player has shield up" to remote clients for rendering. The per-pawn snapshot
state byte is full (bit 7 = `climbing`), so it would cost real wire; the *mechanic* is fully
server-side and gate-proven deterministically without it. Logged as a client-render follow-up.

## F. Loadout / class-select

- `GADGET_RIOT_SHIELD` (=10, already defined) **added to `IMPLEMENTED_GADGETS`** in
  `shared/sim/loadout.gd` → sanitize accepts it; it stops snapping to the Support default.
- Class-select `ClassSelectPanel`: **un-grey the Riot Shield option** (drop its "(coming soon)"),
  add a one-line effect blurb ("bulletproof frontal cover; slower, no primary fire").

## G. Bot AI (`bots/`)

- Support bots that roll `GADGET_RIOT_SHIELD` **raise the shield (`BTN_SHIELD`) when taking frontal
  fire / advancing on a capture**, so the fleet gate exercises the block + break + regen paths
  emergently. Restrained like the other exercisers (no pathological always-up).
- **Deterministic drill** (`tests/riot_shield_*`) is the authoritative proof — see §H.

## H. Testing

**Unit (`shared/sim/riot_shield.gd` + integration):**
- `riot_shield_geometry`: `blocks` true dead-ahead, true at the arc edge, false just past it, false
  directly behind; symmetric L/R; wraps correctly across ±π.
- `riot_shield_damage` (server-integration): a frontal bullet is fully absorbed (health unchanged,
  `shield_hp` drops); a flank/rear bullet hits health normally; an explosive/melee/back-stab from the
  front bypasses; a burst that exceeds `SHIELD_HP` breaks the shield (forced down + lockout) and does
  **not** bleed the overflow into health; regen refills after the delay; a broken shield can't raise
  until the lockout expires, then re-arms full.
- `riot_shield_movement` (shared): `shield_up` applies `SHIELD_SPEED_MULT`, forces sprint off, and
  blocks primary fire; the same bit with a non-shield gadget does nothing (gate honored).
- `riot_shield_reset`: respawn restores `shield_hp` full + clears the break lockout; a mid-life
  `SET_LOADOUT` off the shield gadget drops `shield_up` cleanly.
- `protocol`: VERSION == 11; `SELF_STATE` round-trips the `shield_hp_frac` byte; `BTN_SHIELD`
  round-trips through the input frame.

**Gate (per-phase, per spec §J P4-style):**
- **Deterministic drill** builds a shield-Support, an enemy fires frontally (blocked) then flanks
  (hits), a burst breaks it, regen re-arms — all under the tick budget. Authoritative mechanic proof.
- **128-bot `conquest_town` fleet gate** on game2: no tick/bandwidth regression (no per-tick stream
  added; SELF_STATE +1 byte is negligible), Conquest reaches a winner, `script_errors=0`, with
  shield-Support bots in the mix. Reported counters: shields raised / hits blocked / breaks.

## I. Budgets

- **Tick:** the block is a fast-out (`if not victim.shield_up`) on the existing damage path; the
  bearing it needs is already computed. Shield regen is an O(manned-shields) step, tiny. No new
  per-tick stream.
- **Bandwidth:** `SELF_STATE` +1 byte/client/stride; no SNAPSHOT change. Negligible.

## J. Out of scope (explicit)

- **Sidearm-while-shield** (BattleBit lets you pistol behind the shield) — v1 blocks all primary
  fire; sidearm-behind-shield is a follow-up needing weapon-swap plumbing.
- **Remote-client shield rendering** — deferred visual follow-up (§E).
- **Shield melee bash / shield-as-structure cover for teammates** — not in v1.
- **Grapple (Assault)** — the last remaining M19 heavy gadget; its own later phase.

## K. Coordination

- A concurrent agent owns **M9-P2 (rating / online services, `backend/`)** — no overlap with this
  sim/wire work. Before landing, `git fetch origin` and confirm nothing else bumped `Protocol.VERSION`
  past 10 (AGENTS.md §13); reconcile if so.
