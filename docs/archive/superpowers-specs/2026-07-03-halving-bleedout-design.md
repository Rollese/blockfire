# DBNO Halving Bleedout — design

**Date:** 2026-07-03 · **Status:** approved-pending-review · **Area:** sim / gameplay (shared + server + bot + client)

## Problem

Two defects surfaced in the M7 client gate (2026-07-03):

1. **Downed enemies never die / pile up.** The M7.5-P3 support AI makes a downed bot self-bandage
   once, which sets `Pawn.bleed_halted = true`; `Revive.bleed_step` then returns `bleed_health`
   unchanged, so the pawn **never bleeds out**. Bots have no give-up behaviour, so any downed bot a
   medic doesn't reach lies on the ground for the rest of the match (still counted `alive`). The
   in-code claim "bandages are finite, so matches still end by bleed-out" is false: one bandage
   halts the entire down (a downed pawn takes no further damage to spend more).
2. **Bleedout is a flat 8 s**, not the BattleBit-style escalating pressure the game wants.

## Goal

Replace the flat 8 s bleedout + permanent self-bandage halt with a **halving bleedout** that
guarantees every down resolves (bots and humans alike), matching BattleBit feel: ~60 s the first
time you go down, halved on each subsequent down **within the same life**, until the window is
shorter than a revive can complete (effectively unsaveable) and finally an outright kill.

## Decisions (owner-ratified 2026-07-03)

- **Self-bandage while downed: removed.** BattleBit has no downed self-bandage (bandages apply only
  to *bleeding-while-standing*, a mechanic blockfire does not yet have). The bleed can only end by
  revive or bleed-out.
- **The bandage item stays.** `bandage_count`, its spawn grant, ammo-resupply refill, `SELF_STATE`
  wire field, and HUD count are **retained** — reserved for the future standing-bleed bandaging
  feature. Only the *downed self-bandage action* and its *halt* are removed.
- **Initial window 60 s, halve to zero.** No floor; once the window reaches 0 the down is skipped
  and the hit kills outright. "Eventually instant" then falls out naturally (see table).

## Mechanic (shared/sim/revive.gd + shared/sim/pawn.gd)

- New pawn field `down_count: int = 0` — number of times downed **this life**; reset to 0 on spawn.
- On entering DBNO: `down_count += 1`, and the bleedout window (ticks) is

  ```
  window = INITIAL_BLEEDOUT_TICKS >> (down_count - 1)      # 1800 >> (n-1), 30 Hz
  ```

  | down # (n) | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | … | 12 |
  |---|---|---|---|---|---|---|---|---|---|---|
  | window ticks | 1800 | 900 | 450 | 225 | 112 | 56 | 28 | 14 | … | 0 |
  | seconds | 60 | 30 | 15 | 7.5 | 3.7 | 1.9 | 0.9 | 0.5 | … | 0 |

- **Instant kill when `window <= 0`** (n ≥ 12): fold into the existing DBNO-entry decision alongside
  `Revive.is_instant_kill(headshot, source)` — the pawn skips DBNO and dies outright.
- **Dynamic floor.** Today `bleed_health` drains 0 → fixed `BLEEDOUT_FLOOR (-240)`. Generalise: the
  floor becomes `-window`, stored per-pawn as `bleed_floor: int` (set at down-time). The pure
  helpers take the floor as a parameter:
  - `bleed_step(bleed_health, floor) -> maxi(floor, bleed_health - BLEED_RATE)` (halt branch gone).
  - `is_bled_out(bleed_health, floor) -> bleed_health <= floor`.
  - `bleed_frac_u8(bleed_health, floor)` — urgency 255→0 over the (now variable) window; a shorter
    window simply drains the revive marker faster, which reads correctly.
  - New `bleedout_window(down_count) -> int` (the `>>` formula, clamped ≥ 0) with
    `const INITIAL_BLEEDOUT_TICKS := 1800`.
- **Emergent "eventually instant" (no special-casing).** Non-medic revive = 90 ticks (3 s), medic =
  45 (1.5 s). The window drops below non-medic-revivable at **down #6** (56 < 90) and below
  medic-revivable at **down #7** (28 < 45). So late-life downs become unsaveable through the ordinary
  race between the drain and the revive hold — the `window <= 0` skip is only the final backstop.

## Removals (self-bandage action + halt)

Retain `bandage_count` everywhere; remove only the downed self-bandage path and the halt flag's
*gameplay effect*:

- `shared/sim/revive.gd` — drop the `halted` branch from `bleed_step` (signature changes to take
  `floor`).
- `shared/sim/pawn.gd` — `bleed_halted` stays as an **inert, always-false** field (keeps the
  `SELF_STATE` / `DOWNED_LIST` wire layout stable — no renumbering, no codec churn) but is never set
  true. `down_count` + `bleed_floor` added; both reset on spawn.
- `server/support.gd` — `handle_self_bandage` becomes a no-op / removed; `bleed_halted` is no longer
  written. `handle_give_up` **unchanged** (a human may still skip the wait).
- `server/server_main.gd` — DBNO entry (`:568`) increments `down_count` and sets `bleed_floor` from
  `bleedout_window`; DBNO-entry decision adds the `window <= 0 → outright kill` case; spawn (`:924`)
  resets `down_count`. `SELF_BANDAGE` message id stays **reserved/unused** in the registry (stop
  routing it; do not renumber — see wire-protocol-registry.md).
- `bots/ai/behaviors/support.gd` + `bots/bot_driver.gd` — remove `should_self_bandage` and the
  downed-branch self-bandage send (the branch just holds still and waits/bleeds now); drop the
  `bandaged` per-life latch.
- `client/` — remove the downed-overlay bandage prompt + the `bleed_halted` "Stabilized" latch; the
  downed timer reflects the shorter window via the existing `bleed_frac_u8`. The HUD bandage **count**
  (healthy state) is untouched.

## Testing (AGENTS.md §10 — deterministic)

- `tests/revive_test.gd`: `bleedout_window` halves per down and clamps at 0; `down_count` resets on
  respawn; `bleed_step` drains to the dynamic floor and no longer halts; `is_bled_out` fires at the
  floor; window ≤ 0 ⇒ instant kill; revive-crossover (down #6 window < non-medic revive; down #7 <
  medic revive).
- Codec/UI regression: `SELF_STATE`/`DOWNED_LIST` round-trip unchanged (bleed_halted inert);
  downed-overlay no longer shows a bandage prompt.
- **Fleet gate** (128-bot, existing harness): confirm no downed pile-up (downed pawns resolve),
  `bleedouts` > 0, matches still reach a winner, tick within budget.

## Out of scope

- Standing-bleed ("bleeding while up") + its bandage cure — future work; this design only *reserves*
  the bandage item for it.
- Client feel-tuning of the revive-marker urgency curve (owner-gated).
