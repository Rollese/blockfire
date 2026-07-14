# M2 — BattleBit ammunition / magazine system — design

Status: **approved** (owner brainstorm 2026-07-14). Closes the "Full BattleBit ammo/magazine
system" backlog item deferred out of M17 (`docs/TASKS.md` M2 backlog spec, owner-requested
2026-07-13). Own milestone track (M2 backlog), spec → plan → subagent-driven TDD.

## Problem

M17 gave weapons a **flat reserve pool**: `c["ammo"]` (loaded mag) + `c["reserve"]` (a single spare-
round int); a reload moves `min(mag_size - mag, reserve)` rounds in with **no partial-mag discard**,
and the ammo box / medic ammo-give / ammo bag top the reserve to full almost instantly. That is not
BattleBit's model. BattleBit tracks **individual magazines**, each remembering its own round count,
with the survivability tension that comes from managing them: you can get caught reloading a half-
empty mag, you consolidate partials between fights, and a fast reload trades ammo for speed.

## Owner-ratified mechanics (brainstorm 2026-07-14)

1. **Individual magazines.** Each spare mag tracks its own round count. Reloading returns the current
   partial mag to inventory (not merged). All mags reset to full on death/respawn.
2. **FIFO reload (tap-R).** A normal reload appends the current partial mag to the tail of the spare
   queue and pops the head as the new loaded mag — **skipping any 0-round mags** (never chamber an
   empty). You can therefore end up loading a half-spent mag mid-fight — the tension that makes
   redistribution matter.
3. **Fast reload (hold-R) — 0.75× reload time, drops a recoverable mag.** Hold-R reloads 25% faster
   but **drops the current mag as a world pickup** at the player's position. The owner reclaims it by
   looking at it and pressing **F** (re-adds it as a spare mag with its remaining rounds). **Owner-
   only** — other players cannot pick up your mags. Despawns on the owner's death/respawn and after a
   safety timeout.
4. **Redistribution (hold key, 5s per mag).** Holding the redistribute key consolidates one partial
   mag every 5s: pours the emptiest spare into the fullest non-full spare, dropping the resulting
   empty from inventory. Locked out of firing while it runs; cancels on release or on taking damage.
5. **Slow resupply — 1 mag / 5s.** The ammo crate / Support `give_ammo` bag / medic ammo-give add
   `mag_size` rounds every 5s (filling the emptiest spare mags first, up to the weapon's max mag
   count), instead of instant-to-full. Respawn/deploy still resets to full (bots never go dry → fleet-
   gate combat density unchanged).

## Representation (core architectural decision)

Keep `c["ammo"]` as the **loaded-mag** round count. Replace the flat `c["reserve"]` int with
`c["spare_mags"]` — a **FIFO list of `u8` round-counts**, one per spare magazine, **per weapon slot**
(both slots in `_SLOT_FIELDS`).

- **Spawn/deploy/reset** builds N full spare mags where `N = reserve_ammo(wid) / mag_size` (all
  weapons divide evenly: AR 6, SMG 6, DMR 7, PISTOL 4, LMG 3), scaled by the class `reserve_mult`
  trait (Support carries extra spare mags — round to whole mags). **Total ammo budget unchanged →
  zero balance change vs M17.**
- `reserve` (total spare rounds) becomes a **derived** value `sum(spare_mags)`, kept only for the
  server-side resupply-cap math and any legacy read site — **never shown to the player**.
- Only the **write** sites change (spawn / reload / resupply / give_ammo); most read sites that used
  `reserve` for a cap can read `sum(spare_mags)`.

Rejected alternatives: a uniform `mags[]`-with-loaded-at-index-0 array (forces a larger predictor
rewrite for no faithfulness gain); keep-flat-and-derive-mags (cannot track individual partial mags —
fails the feature outright).

## Shared sim (`shared/sim/weapon.gd`)

Pure, deterministic, oracle-testable helpers (mirrors the existing `reload_fill` seam so server and
client `WeaponPredictor` share one implementation and the HUD never drifts):

- `spawn_mags(weapon_id, reserve_mult) -> Array` — build the full spare-mag FIFO for a fresh loadout.
- `reload_swap(mag, spare_mags) -> [new_mag, new_spare_mags, ok]` — FIFO tap-reload: append `mag` to
  tail, pop first non-empty head as `new_mag` (discard skipped 0-mags), `ok=false` if no non-empty
  spare exists.
- `redistribute_step(spare_mags, mag_size) -> Array` — one consolidation step (pour emptiest into
  fullest non-full, drop the emptied mag); returns the new list (unchanged if nothing to consolidate).
- `resupply_step(mag, spare_mags, weapon_id, reserve_mult) -> [mag, spare_mags]` — add `mag_size`
  rounds, emptiest-mag-first, capped at max mag count + full loaded mag.

Fast-reload drop and pickup reuse `reload_swap` for the swap; the drop/reclaim of the mag object is
server/entity state (below), not a sim helper.

## Server (`server/server_main.gd`, `server/support.gd`, `server/fire.gd`)

- Reload-complete: `reload_swap` (tap) or drop-then-`reload_swap` (fast). Fast reload takes **0.75×**
  the weapon's normal reload tick-duration; a `fast` flag carried on the in-flight reload record.
- **Dropped mags**: a new server-owned list keyed by owner (ReliableList pattern, like C4/mines/
  emplacements). Fast reload spawns `{id, owner, pos, rounds}`. `PICKUP_MAG` validates owner + alive +
  look-ray hit + range, then re-appends the mag to `spare_mags` and removes the entity. Swept on the
  owner's death/respawn and disconnect (join the existing per-owner cleanup sweeps), and on a safety
  timeout.
- **Redistribute**: a held-`BTN_REDISTRIBUTE` state machine — one `redistribute_step` every 5s while
  held, fire-locked, cancels on release or on `_apply_pawn_damage`.
- **Slow resupply**: the ammo box / `Support.give_ammo` / medic ammo-give call `resupply_step` on a
  5s-per-mag cadence instead of topping `reserve` to full. The ammo-fullness early-out uses
  `sum(spare_mags)` + loaded vs the max.

## Wire (`shared/net/protocol.gd`) — VERSION 12 → 13

- **SELF_STATE** (msg 22, owner-only, reliable, append-only): after `grapple_charges`, append
  `u8 spare_count` then `spare_count × u8` round-counts for the **active slot**. `get_available_bytes`-
  guarded, decodes empty when a pre-13 peer omits it. The existing `reserve` u16 field stays in place
  (server sets it to `sum(spare_mags)`) so mid-message layout is untouched.
- **`DROPPED_MAG_LIST` = 54** (server → owner client, reliable, rebuilt-on-change like `GADGET_LIST`):
  `{id, x, y, z, rounds}` for the owner's dropped mags → world marker + "F to pick up" prompt.
- **`PICKUP_MAG` = 53** (client → server): reclaim dropped mag `id`.
- **Input bits** (`shared/net/input_command.gd`, buttons already u16): `BTN_FAST_RELOAD = 2048`
  (bit 11, hold-R), `BTN_REDISTRIBUTE = 4096` (bit 12). Tap-R keeps `BTN_RELOAD = 128`.

## Client (`client/weapon_predictor.gd`, HUD, input)

- `WeaponPredictor` tracks `spare_mags`; predicts FIFO tap-reload, fast-reload-drop (0.75×),
  redistribute, and slow-resupply; `reconcile()` snaps `spare_mags` to the authoritative SELF_STATE.
- **Input**: client detects **hold-vs-tap** on the reload key (tap < threshold → `BTN_RELOAD`; hold →
  `BTN_FAST_RELOAD`); a new bound `redistribute` action → `BTN_REDISTRIBUTE`; `PICKUP_MAG` emitted on
  the interact/F key when a dropped mag is aimed at.
- **HUD (BattleBit-faithful):**
  - **Loaded mag = number only** (existing large ammo readout, `"%d"` — the old `"%d / %d"` reserve
    number is removed).
  - **Spare mags = a glyph strip**: one icon per spare mag, each **filled bottom-up** by its round
    fraction `rounds / mag_size` — fully grey = empty, fully white = full, partials fill
    proportionally. Driven directly by the `spare_mags` list.
  - **No reserve total is ever shown as a number.**
  - Dropped-mag world markers + "F to pick up" prompt when aimed at the owner's own dropped mag.

## Bots & fleet gate

Bot exercisers (`bots/exercisers.gd`) occasionally **fast-reload** (drop), **redistribute**, and
**pick up** their dropped mags, so the 128-bot `conquest_town` gate exercises every path with non-zero
telemetry (`mags_dropped`, `mags_picked`, `redistributes`) and stays stable (< 33.3 ms tick,
0 script errors). Respawn/deploy full-reset keeps bots from ever running dry (combat density
unchanged from M17).

## Testing (deterministic, headless — no playtest needed for the mechanic)

- `weapon_test`: `spawn_mags` builds the right count/fullness per weapon (+ Support `reserve_mult`);
  reserve values still divide evenly.
- `weapon_predictor_test`: FIFO tap-reload order + skip-empty; fast-reload drops + 0.75× duration;
  redistribute one-step consolidation; slow-resupply emptiest-first; `reconcile` snaps `spare_mags`.
- server: reload-complete FIFO (tap) + drop (fast); dropped-mag spawn → `PICKUP_MAG` roundtrip;
  owner-only pickup reject (wrong owner / out of range / dead); redistribute 5s cadence + damage
  cancel; slow-resupply 5s/mag rate + cap; spawn/respawn/disconnect sweeps dropped mags.
- `protocol_test`: SELF_STATE `spare_mags` roundtrip + back-compat decode when absent;
  `DROPPED_MAG_LIST` + `PICKUP_MAG` roundtrip; VERSION == 13.
- Then the 128-bot `conquest_town` fleet gate (evidence in `docs/gate-evidence/`).

Client HUD text/glyph feel is validated by the owner on the next playtest (the mechanic itself is
fully covered headlessly).

## Out of scope / deferred

- **RPG rockets** stay gadget-managed (`c["rockets"]`) — no mag model (as in M17).
- Enemy/remote dropped-mag visibility (owner-only render for v1; a shared list would need a wider
  interest cost — defer if ever wanted).
- Mag-glyph art polish (icon shape/anim) — owner playtest feel item.
