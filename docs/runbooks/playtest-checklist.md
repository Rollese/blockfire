# Playtest Verification Checklist

Aggregates the **human / visual / AI-dependent** verification points that headless gates can't
cover, for the **one large playtest** to be run once the parallel workstreams (M7 art, M7.5 bot AI,
M11 destruction, …) have all landed on `master`.

**How to use:** each workstream appends its own clearly-titled section below (append-only to avoid
merge conflicts between parallel agents). During the playtest, walk each section's checkboxes.
Many points are deferred here precisely *because* the combat AI was mid-rewrite and AI-based
full-match runs couldn't validate them (see `docs/TASKS.md` ⚠ note).

---

## M11 — Destructible Buildings (Phase 1: chunked store, merged 2026-06-18)

P1 unified `StructureStore` onto a 0.25 m sub-cell chunk model and changed how structures take
damage. Only P1 (the sim substrate) is built; cascade/collapse (P2), building authoring + art (P3),
and the client cosmetic layer (P4) are not yet in. These points verify P1 didn't break existing M4
building/destruction *feel* and that the new chunk damage behaves, on the rendered client + with a
working combat AI. Spec: `docs/specs/destructible-buildings.md`; milestone: `docs/milestones/M11-destructible-buildings.md`.

- [ ] **Player-built wall durability under gunfire.** Bullets now *carve chunks* (`BULLET_CARVE_RADIUS = 0.30 m`) rather than depleting a 350-HP pool. Shoot a built wall: does it take a sensible number of rounds to breach, and does the breach read right? **Gate-tune `BULLET_CARVE_RADIUS`** (server_main.gd) if walls feel too tanky or too fragile vs the old M4 feel.
- [ ] **Explosive structure destruction.** Frag / RPG / C4 carve chunks within the blast radius and remove pieces at full carve. Confirm a grenade/RPG on built cover destroys it about as before (M4 `destroyed`/`nades` behaviour), and pieces vanish cleanly (no ghost collision).
- [ ] **Partial walls still block (expected P1 limitation).** Hole-aware march was **descoped** from P1 — a partially-damaged wall **still blocks bullets/LOS until fully destroyed**. Confirm you *cannot yet* shoot/see through a visible hole, and judge whether that reads as acceptable for the playtest or should be prioritised in the later hole-aware phase.
- [ ] **Damage visualisation gap (known, P4).** `client/world_renderer.gd` still renders structures **pristine** regardless of chunk damage (it reads a now-removed `bucket` field). Confirm *removal* shows (a destroyed piece disappears) even though *partial* damage/holes do **not** render yet. Partial-hole VFX + the brick-debris/collapse cinematic are the P4 client-cosmetic layer.
- [ ] **No M4 building regression.** Place / cap-recycle / cover / movement-collision against built pieces all still work as in M4 (the store was refactored under them). Build a few pieces, confirm cover blocks, recycle at the cap.
- [ ] **Bot ↔ structure interaction (needs the combat-AI rewrite live).** Once bots fire and build again: bots firing through cover should chew walls down; bots fragging cover should destroy it; bot-built cover should accumulate then get destroyed. (This is the behaviour the headless M4 smoke *would* have shown but couldn't, with the AI mid-rewrite.)
- [ ] **Tick/bandwidth under load with destruction active.** With a working AI fighting at scale (≥48, ideally 128), confirm chunk damage + `OP_CHUNK` deltas add no tick-budget breach (headless showed it event-driven and cheap, but re-confirm live).
- [ ] **Melee does NOT affect structures yet.** Sledge/pickaxe wall-breaking is **not** in P1 (the melee gadget is M5.5-P3; M11 owns only the future hook). Confirm only bullets + explosives change structures right now.

<!-- Other workstreams: append your section below this line. -->

---

## M14 — Walkable Multi-Floor Structures (implemented 2026-06-19)

Verify on `conquest_arena_buildings` — the **`test_twostory`** building is the target (a 3×3 two-story
box: south door → interior staircase → first-floor room ringed by windows → flat roof). Spec:
`docs/specs/walkable-multifloor.md`; milestone: `docs/milestones/M14-walkable-multifloor.md`.

- [ ] **Walk into the ground floor.** Enter through the door; confirm the ground-floor walls block but the doorway is passable.
- [ ] **Climb the staircase.** Walk forward onto the interior stairs — you should ascend smoothly (ramp), not get stuck at the bottom and not teleport up. Arrive standing on the first floor.
- [ ] **Stand on the first floor.** You're held at the upper level; you can move around the first-floor room and shoot out the windows.
- [ ] **Per-floor wall collision.** On the first floor, the upper walls block you; standing on the ground floor directly below those same walls, you are NOT blocked (height-aware).
- [ ] **Step off / drop down.** Walk off the first-floor edge (or out a window) → you fall to the ground.
- [ ] **Fall damage curve.** A short drop (first floor, ~2–4 m) does little/no damage; a bigger drop hurts; jumping off the **roof** (~6 m) should be lethal or near-lethal (safe ≤ 4 m, lethal ~12 m — tune `Fall.SAFE_FALL`/`DMG_PER_M` if it feels off).
- [ ] **Fall death reads right.** A lethal fall **kills outright** (not downed/DBNO) — confirm you die, not bleed out.
- [ ] **Destruction still works on a multi-floor building.** RPG/frag the ground-floor walls/stairs; pieces above lose support and the building cascades/collapses as in M11. (Destroying the floor under you should drop you.)
- [ ] **Stair direction.** Confirm the stairs ascend the way you walk in; if they run backwards, it's a one-line flip of `Stairs.run_dir`'s base case.
- [ ] **No vertical jitter.** Standing on an upper floor should be stable (server-authoritative + reconciled). If you see rubber-banding/jitter on the upper floor, note it — a client-side floor-snap is the follow-up.
