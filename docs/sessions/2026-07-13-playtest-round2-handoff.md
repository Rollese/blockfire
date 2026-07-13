# Handoff — Playtest Round 2 (2026-07-13)

**Status:** All round-2 playtest fixes are **landed on master `ab82b77`** and were **live-verified**
(server + 24 bots on game2, laptop client peer 25 `LaptopR2`, tick ~1.8 ms, suite **1872/0**).
The live playtest sessions were **torn down** at the owner's request to pause. Nothing is
uncommitted. This doc is the pickup point for the next agent.

Full per-item record with commits + root causes: `docs/TASKS.md` → "Post-playtest fixes — 2026-07-13"
→ "Round 2". Deep memory: `blockfire-playtest-fixes-20260713.md`.

---

## What round 2 delivered (8 fixes, TDD + two-stage review each)

Owner re-playtested the round-1 build on the laptop. Confirmed OK: A4 (fixed size), M3 (rubble
blocks), Z1 exterior z-fight gone. Remaining feedback + 2 new bugs were fixed. The three
"investigate" items each got a read-only root-cause pass first (systematic-debugging) — all three
root causes were non-obvious:

| Item | Commit | One-line |
|---|---|---|
| A4 loadout auto-closes | `a8fa49f` | `DeployMenu.populate()` force-hid the editor; re-runs on FOB_LIST churn → decoupled. |
| M1 bandage HUD | `4707d8e` | green "BANDAGES" text → procedural glyph + white count. |
| G1 grapple rope 1px | `3f7081b` | `PRIMITIVE_LINE_STRIP` → shaded low-poly tube (r=0.045, 6 sides). |
| G2 shield too tall / opaque | `40d8fe1` | shorter (0.60→0.42) + lowered + transparent center window. |
| G3 LMG nest ugly | `0150467` | curved sandbag parapet + firing embrasure, turret removed, sandy NEAREST texture. |
| Z1 roof-slab gaps | `b309bf2` `bae70e4` | round-1 inset opened gaps → OVERSIZE (`CELL+0.02`) so slabs overlap. |
| Bug1 invisible walls inside buildings | `ee41528` `0534638` | floors collided vs bullets as a full 2.4 m cube → thin `FLOOR_COLLISION_THICK=0.35` slab. |
| Bug2 tracers through walls | `503a313` `2119829` | 80 m box never clipped → clip to first `struct_store.march` hit (+ local-basis-scale fix). |

No wire/VERSION change in the whole batch → native snapshot-encoder `.so` stays valid.

---

## What the OWNER still needs to eyeball (re-playtest checklist)

The owner paused before confirming the round-2 visuals. On resume, ask them to verify:
- **G3 nest** — the big one: does it read as sandbags, cover the prone gunner, and can they
  actually **see + shoot out** through the embrasure across the traverse? (The embrasure is placed
  at the verified prone-gunner eye = `Emplacement.seat_world()` [`pos − forward·0.6`, at ground]
  + prone eye 0.45 = local (0, 0.45, −0.6). Do NOT confuse `seat_world()` with `muzzle()`
  [`+fwd·0.8 + up·1.1`] — a prior agent did.)
- **G2 shield** — shorter, sky visible above, transparent center window reads as tactical.
- **Z1** — no gaps between roof slabs, exterior z-fight still gone.
- **Bug1** — shots inside buildings (esp. upstairs) no longer eat on invisible walls.
- Plus A4 / M1 / G1 / Bug2 quick confirms.

---

## Known residuals / review nits (non-blocking, documented)

- **G3 nest is no longer team-colored** (now sandy, per the owner's "read as sandbags" ask). If the
  owner wants a subtle team accent back, that's a ~1-line tweak in `client/art/lmg_nest_kit.gd` /
  the `_apply_nest_damage` base color.
- **G3 embrasure** — a max-elevation (+25° pitch) shot grazes the front cap by ~7 mm. Sandbags have
  NO collision (visual only) so it doesn't affect gameplay; if it ever looks wrong, nudge the cap
  bottom (`CAP1_Y`) from 1.10 to ~1.13.
- **Z1** — adjacent floor cells at DIFFERENT damage buckets can show a thin flickering seam in the
  0.02 m overlap band (rare; better than the round-1 gap). Only if a building is partially damaged.
- **G3** — `world_renderer.nest_barrel_visible` + the Barrel-guard branch are now dead for the nest
  kit (kept as a defensive guard). Harmless; could be removed later.

---

## Deferred backlog (owner-directed — do NOT start without owner go-ahead)

- **G4** — BREACH / REPAIR / STIM / SMOKE_WALL gadget verification (needs multiple human players +
  vehicles). Post-alpha client polish.
- **Enemy / remote riot-shield 3D visibility** — only the LOCAL first-person shield ships. Making
  the shield visible on other players needs a new `EntityState.q_state` bit (the byte is full:
  stance/lean/team/alive/downed/climbing) → wire VERSION bump + native encoder change.
- **M2 — full BattleBit ammo/magazine system** (owner-requested, own milestone). Spec is in
  `docs/TASKS.md` → "M2 — BattleBit ammunition system". Slow resupply (~1 mag/few sec), individual
  mags back to inventory, hold-key ammo redistribution, hold-R fast-reload drops the mag.

---

## How to resume the playtest (game2 = 192.168.1.166, dev session runs ON it)

Server + bots (from `~/projects/blockfire` on game2, native encoder, port 27015):
```
tmux new-session -d -s bf-pt-server "godot --headless --path . -- --server --port=27015 --map=conquest_town --tickets=999999 --time-limit=36000 2>&1 | tee <log>"
tmux new-session -d -s bf-pt-bots   "godot --headless --path . -- --bots --bot-count=24 --connect=127.0.0.1 --port=27015 --map=conquest_town 2>&1 | tee <log>"
```
Laptop client (.116, godot4.7/iGPU, fish → wrap in `bash -lc`; `--import` first or grey):
```
ssh roland@192.168.1.116 'bash -lc "cd ~/projects/blockfire && git pull && godot --headless --path . --import && setsid bash -c \"env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 godot --path . --rendering-driver vulkan -- --connect=192.168.1.166 --port=27015 --name=LaptopPT\""'
```
Gotcha: the repo tracks test `.uid` sidecars (280). A checkout with them UNTRACKED (fresh import)
will block `git merge --ff-only` — `git clean -f tests/*.uid` (or `git stash -u`) before pulling.

**Separate track — do NOT disturb:** another agent runs `conquest_caspian` (BF4 Caspian Border map,
Phase 1, merged to master `7d75e7f`) from `~/projects/bf-caspian` on **port 27020**
(tmux `caspian-srv`/`caspian-bots`, `ENCODER=gd`). That is unrelated to this playtest.
