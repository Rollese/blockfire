# Reserve-ammo economy — spec

Status: implemented (branch `m17-reserve-ammo`, 2026-07-10). Owner AFK; decisions default to
BattleBit per the working agreement (AGENTS.md §9). Closes the "reserve-ammo economy" item
deferred out of M7 (see `docs/TASKS.md` M7 deferral list).

## Problem

Reload currently refills the magazine **for free** — every weapon has effectively infinite ammo.
`server/fire.gd:104` starts a reload whenever `ammo < mag_size`; `server_main.gd` reload-complete
sets `ammo = mag_size` with no cost. The ammo box / medic ammo-give top the mag to cap for free.
The client already anticipates this gap: `client/weapon_predictor.gd` header says "finite reserve
is a later combat-depth item" and the HUD literally renders `"%d /∞"`.

This removes a core BattleBit survivability/gunplay lever: ammo is a finite resource you manage,
and the Support class / ammo crates matter because they replenish it.

## Model (BattleBit-default)

- Each hit-scan weapon carries a finite **reserve** bullet pool separate from the loaded mag.
  Flat pool, **no partial-mag discard** on reload (BattleBit behaviour): a reload moves
  `min(mag_size - mag, reserve)` rounds from reserve into the mag.
- Reserve sizes (~6 spare mags for primaries, marksman a touch more, pistol fewer):

  | weapon | mag_size | reserve | spare mags |
  |--------|----------|---------|-----------|
  | AR     | 30       | 180     | 6 |
  | SMG    | 35       | 210     | 6 |
  | DMR    | 20       | 140     | 7 |
  | PISTOL | 15       | 60      | 4 |

- **RPG is out of scope** — its rocket pool is gadget-managed (`c["rockets"]`) and stays as-is
  (documented follow-up if we want finite rockets).
- A reload only starts when `mag < mag_size` **and** `reserve > 0`. Reserve 0 → you fight with
  whatever is in the mag until you resupply or respawn.
- **Resupply** refills the reserve to its weapon max (and tops the mag), so ammo crates / the
  medic-class ammo-give / ammo bags are the way to top up mid-life. Respawn/deploy/slot-swap reset
  reserve to full (bots therefore never stay dry — keeps fleet-gate combat density unchanged).

## Wire

`SELF_STATE` (msg 22, owner-only, reliable) gains a trailing `reserve` u16, append-only and
`get_available_bytes`-guarded like the existing trailing fields (decodes `-1`/default when a
pre-6 peer omits it). `Protocol.VERSION` 5 → 6. No other message changes.

## Client

- `WeaponPredictor` gains `reserve`; predicts the deduct on reload-complete and the reserve>0
  reload-start guard, and `reconcile()` snaps reserve to the authoritative SELF_STATE value.
- HUD ammo readout: `"%d / %d"` (mag / reserve) instead of `"%d /∞"`; low-reserve tint reuses the
  existing low-ammo colour path.

## Tests (deterministic, headless — no playtest needed for the mechanic)

- `weapon_test`: reserve fields present + sane per weapon.
- `weapon_predictor_test`: reload deducts reserve (no discard); reload blocked at reserve 0;
  reconcile snaps reserve.
- server reload-complete deducts reserve, keeps partial mag; reload-start guarded on reserve>0.
- resupply (ammo box + `Support.give_ammo`) refills reserve.
- `protocol_test`: SELF_STATE reserve roundtrips + back-compat decode when absent.

Client HUD text/tint is a one-line bind change validated by the owner on the next playtest (the
mechanic itself is fully covered headlessly).
