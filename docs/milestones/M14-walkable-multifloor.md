# M14 — Walkable Multi-Floor Structures

**Status:** implemented + unit-verified (2026-06-19) · **Branch:** `m14-walkable-multifloor` · **Spec:** [`walkable-multifloor`](../specs/walkable-multifloor.md) · **Plan:** [`2026-06-19-m14-walkable-multifloor`](../plans/2026-06-19-m14-walkable-multifloor.md)

## Objective

Make destructible structure pieces walkable in the vertical dimension: pawns stand on structure
floors, walls block per-floor, staircases are walkable ramps, and falling off a height deals
BattleBit-style fall damage. Built entirely on the M4.5-P3 vertical-movement system
(`Ladder.platform_floor` + `SimLoop._apply_platform_floor` + `Vault`); **no protocol change, no
client-prediction change** (verticality is server-authoritative + reconciled, exactly like the
existing ladders/platforms).

## What landed

- `Stairs` (`shared/sim/stairs.gd`) — pure ramp-height math (`run_dir`, `surface_at`).
- Catalog `surface`/`ramp` flags (`bfloor` is a flat walkable surface; `bstair` is a ramp).
- `StructureStore.floor_height_at(x,z,y)` — highest walkable structure surface at/below a height
  (floors → cell-base plane; stairs → ramped). Per-surface catch reach: flat `0.35 m`, ramp `0.6 m`
  (= max per-tick sprint climb on a 1:1 slope + margin; avoids both stuck-on-ramp and teleport-up).
- Height-aware horizontal collision (`StructureStore._blocks_ground`) — samples the cell at the
  pawn's feet, so a 2nd-floor wall blocks only when the pawn is up there; floors/stairs/doors are
  walk-through.
- `SimLoop._apply_platform_floor` folds `floor_height_at` in → pawns stand on floors + climb ramps.
- Height-based fall damage: `Fall` curve (`shared/sim/fall.gd`, `SAFE_FALL = 4 m`, lethal ~12 m);
  `Pawn.fall_peak_y`/`landed_fall` tracked by `SimLoop`; `server_main._apply_fall_damage` applies it
  via the normal damage path; `Revive.is_instant_kill` now includes `FALL` (a fatal fall kills, not
  DBNO); fall state is reset on (re)deploy to prevent phantom respawn damage.
- `client/art/building_kit.gd` — `bfloor` mesh top aligned to the walkable cell-base plane.
- `buildings/test_twostory.json` + placed on `conquest_arena_buildings` — a minimal walkable 2-story
  box (door → interior stair → first-floor room ringed by windows → roof) for the gate + playtest.

## Gate

- **Deterministic mechanic tests — DONE.** Full suite **643 run / 0 failed** (M14 added: `stairs_test`,
  `structure_floor_test`, `structure_height_collision_test`, `sim_loop_multifloor_test`, `fall_test`,
  catalog surface/ramp + revive FALL). Covers: floor-height query, stair ramp surface, height-aware
  collision (upper wall blocks / ground clear / floors-stairs-doors walk-through), pawn settles onto a
  structure floor, walks a stair ramp up, `landed_fall` records the drop, fall is instant-kill.
- **128-bot tick gate — substrate confirmed; full fleet run pending.** 12-bot arena smoke (with the
  multi-floor map + height-aware collision + floor queries live) ran clean: bots connect + fight
  ground-level, `tick_mean ≈ 5.4 ms`, no script errors. The floor query is O(building-height) cell
  lookups per pawn — no per-tick scan; re-confirm `move`/`snap` on the 128-bot fleet (operator).
- **Human playtest (feel) — PENDING.** See the M14 section in `docs/runbooks/playtest-checklist.md`.

## Out of scope (v1 — see spec)

Ceiling/headroom bonk; bot multi-floor pathing (humans-only v1); finer sub-cell grid (next building
milestone); `bladder` structure ladder piece; sloped-roof walkability. Local-player vertical position
on structures is server-authoritative + reconciled (no client prediction) — same model as ladders; if
the LAN playtest shows jitter standing on an upper floor, a follow-up can add a client-side floor snap.
