# Plan — Desktop playtest fixes (2026-07-13)

Branch `feat/playtest-fixes-20260713` (worktree `../bf-wt-ptfixes`), base master `2c3e459`.
Source: owner desktop playtest of M16/M17/M19 + FSR build. Backlog codes in `docs/TASKS.md`
("Post-playtest backlog — 2026-07-13"). Deferred items (G4, M2 ammo system, enemy-shield
wire visibility) are recorded there and are **out of scope** for this plan.

**Validation conventions.** Deterministic tasks (server/sim/bot): TDD, and the full suite must
stay green (`godot --headless --path . -s res://tests/run_tests.gd` or the project's runner).
Client-visual tasks: keep tests green where they exist, then the controller validates on game2
via the Xvfb screenshot harnesses (`tools/render_*_shots.gd`, `~/bf-shots`) + owner eyeball.
No `Protocol.VERSION` bump in this plan — every task is wire-compatible.

Tasks are mostly independent; execute in order. Each task: implement (TDD where noted) →
spec-compliance review → code-quality review, per subagent-driven-development.

---

## Task 1 — A4: Loadout panel fixed size (client UI)

**Problem:** `client/menus/class_select_panel.gd` builds the panel in code; the root
`PanelContainer` (`:143-144`) has no `custom_minimum_size`, so it shrink-wraps and the whole
loadout window resizes when a class has more/fewer weapon archetypes or gadgets.

**Change:** give the `panel` `PanelContainer` (`:143`) a fixed `custom_minimum_size` sized to the
worst-case class (the class with the most primary archetypes×variants + widest gadget/armor
rows). Determine the worst case by inspecting `Loadout.allowed_archetypes()` /
`Weapon.variants_of()` / `Loadout.gadget_options()` across all classes; pick a size with modest
headroom for future additions (a comment stating the chosen W×H and why). The panel stays
centered (CenterContainer). Ensure the tallest class's `_primary_box` still fits without the
panel growing past the fixed size — if needed, wrap the primary/left column in a
`ScrollContainer` so overflow scrolls instead of resizing the window, but prefer a size that
fits all *current* classes without scrolling.

**Validation:** existing `tests/class_select_panel_test.gd` stays green. Controller renders the
loadout screen for each class via `tools/render_classselect_shots.gd` and confirms the outer
panel size is identical across classes.

---

## Task 2 — M1: Bandage count on HUD (client, no wire change)

**Problem:** bandage count is on the wire (`SELF_STATE.bandage_count`, decoded at
`client_main.gd:1760` into `_bandage_count`) but never shown — it isn't forwarded into the HUD
model dict, and there is no HUD element for it.

**Change:**
1. Add `"bandage_count": _bandage_count` to the `_hud_model` dict (`client_main.gd` ~`:918`,
   alongside `shield_hp_frac`/`grapple_charges`).
2. In `client/hud/hud_view.gd`, add a `_render_bandage(model)` sub-renderer + its build,
   modeled on the grapple-charges readout (`_render_grapple_charges`, dispatched at `:150`) —
   a small labeled counter (e.g. "Bandages N") near the health/ammo cluster. Hide when count
   is 0 only if that matches sibling readouts' convention; otherwise always show.

**Validation (TDD):** extend `tests/` (mirror the grapple-charges HUD test if one exists, else
add a `hud_view` test) asserting the model carries `bandage_count` and the renderer produces a
node/label for a nonzero count. Controller confirms visually via a HUD screenshot.

---

## Task 3 — G1: Deployed grapple renders as rope, not ladder (client)

**Problem:** `client/world_renderer.gd:3461-3477 set_deployed_ladders()` builds BOTH a
`_make_ladder` red ladder mesh AND a `GrappleRope` verlet rope for every deployed-grapple
entry. `DEPLOYED_LADDER_LIST=51` is exclusively grapple-origin (map ladders render separately
at `:747-759` via `map.ladders` → `_ladder_nodes`), so no wire/flag change is needed.

**Change:** in `set_deployed_ladders()`, stop building the `_make_ladder` mesh for these
entries — render the `GrappleRope` only (verlet rope + its physics line). Keep the node/id
bookkeeping in `_deployed_ladder_nodes` intact (climb collision is server-side and unchanged).
Map ladders (`_ladder_nodes`) keep their ladder mesh — do not touch `_make_ladder` or `:747-759`.

**Validation:** `tests/` — extend a world_renderer test so a deployed-ladder entry yields a node
with a `GrappleRope` child and NO ladder-mesh child. Controller screenshots a deployed grapple
in-world (bot exerciser deploys them) and confirms rope, not ladder.

---

## Task 4 — Z1: Building wall/roof Z-fighting (client mesh)

**Problem:** coplanar faces at the wall-top / roof-floor junction dither. In
`client/art/building_kit.gd`: the `bfloor` slab (`:45-50`) is 0.32 m thick centered at local
`y=-0.12` (top +0.04 above cell base); walls span `y=0..CELL` (`CELL=2.4`), top face at `CELL`.
A storey-N wall's top plane coincides with the roof-storey cell base, and the roof slab's
vertical edges (full `CELL` footprint) coincide with the wall exterior faces → the dithered
band seen under the roof soffit. Collision is server-side and independent
(`structure.gd:floor_height_at` uses the cell-base plane), so a small visual offset is safe.

**Change:** eliminate the coplanar overlap without gaps or collision impact. Preferred: inset
the `bfloor` slab footprint slightly (e.g. `CELL - 0.02`) so its vertical edges sit *inside* the
walls rather than coplanar with the exterior faces, AND/OR raise the slab so its top clears the
wall-top plane by a larger margin than the current +0.04. First **verify `BuildGrid.CELL_SIZE`
(placement, `world_renderer.gd`) == `BuildingKit.CELL` (mesh, 2.4)** — a mismatch would compound
the overlap; if they differ, that's the real bug, fix that instead. Apply the same treatment to
the floor-skirt variant (`:28-41`) if it shares the plane. Do not change `STRUCT_LIFT` globally
(it shifts every piece equally and won't fix coplanarity).

**Validation:** `tests/building_art_kit_test.gd` + `world_renderer_structure_test.gd` stay green.
Controller renders a building close-up at the roofline via `tools/render_town_shots.gd` (or
`render_destruct_shots.gd`) BEFORE/AFTER and confirms the dither band is gone and no gap/seam
was introduced. This task is iterate-with-screenshots.

---

## Task 5 — G2: Riot shield — no regen + visible in first-person + block feedback

Three parts; keep them in one task (same system) but separate commits are fine.

**5a — Remove passive regen (server sim, deterministic).**
`server_main.gd:848-859 _step_shield_regen()` (called `:481`) has two branches to REMOVE:
break re-arm to full (`:854-856`) and passive trickle (`:857-859`). After removal, shield HP
only ever decreases in play; once broken (`shield_hp=0` at `:868-883`) it stays broken.
**Restore points:** keep respawn re-arm (`:975-978`). ADD a `shield_hp` reset (to
`RiotShield.SHIELD_HP`, clear `shield_broken_until_tick`) on **support resupply** (ammo-bag path
`server_main.gd:2478` region) so a support bag re-arms the shield — matching the gadget-restock
model. Consider deleting the now-unused `_step_shield_regen` + its `:481` call, and the
now-unused regen constants in `riot_shield.gd` (`SHIELD_REGEN_DELAY_TICKS`,
`SHIELD_REGEN_PER_TICK`, `SHIELD_BREAK_TICKS`) if nothing else references them.
**TDD:** update `tests/riot_shield_server_test.gd` — assert no passive regen after no-hit delay,
broken shield stays broken (no auto re-arm), and resupply/respawn re-arm to full. Full suite green.

**5b — Visible shield in first-person (client render, no wire).**
The local client knows it is holding the shield (`shield_hp_frac` in SELF_STATE + the held
BTN_SHIELD input). Add a riot-shield viewmodel element to the local first-person view that
appears when the shield is up (in front of / lower-left of the camera, consistent with the
existing viewmodel rig). Reuse a simple box/plate mesh (see `riot_shield_geometry_test.gd` /
any existing shield geometry) with the team color. No 3D shield on remote pawns in this task
(that needs an entity `shield_up` wire bit — deferred, see TASKS.md).
**Validation:** controller screenshots the local view with shield up (support bot / a driven
client) and confirms the shield is visible and doesn't occlude the whole screen.

**5c — Block feedback flash (client, no wire).**
The client can infer a block: when `shield_hp_frac` DROPS between snapshots while the shield is
up, a hit was absorbed. On that transition, trigger a brief screen-border flash (a vignette/edge
pulse, ~0.1–0.15 s) — reuse the existing damage/hit HUD FX pattern if one exists, else a light
Control overlay. On break (`shield_hp_frac` → 0), a stronger flash. Keep it subtle.
**Validation:** controller confirms via the shield-up screenshot sequence; unit-test the
"frac decreased while up ⇒ flash" decision if it can be factored into a pure helper.

---

## Task 6 — G3: LMG nest — force prone + hide own turret barrel + fix bot sky-aim

**6a — Force prone stance while manning (server + client, deterministic).**
`emplacement_server.gd:88-105 step_occupants()` poses the seated occupant but sets no stance.
Set `p.stance = Stance.PRONE` there while mounted, and mirror it in the client seat-lock path
(`client_main.gd:568-582`) so local prediction agrees. Ensure dismount restores normal stance
control. **TDD:** `tests/emplacement_server_test.gd` — a mounted occupant has `stance==PRONE`;
after eject, stance is no longer forced. Full suite green.

**6b — Hide the turret barrel for the local manning player (client render).**
`world_renderer.gd:3562-3599 set_emplacements()` poses the nest's `"Barrel"` child to the turret
aim (`:3596-3598`). `my_id` is already threaded in (`:3563`) and the list carries `occupant`
(`_nest_occupants()` `:3625-3631`). When `occupant == my_id`, hide the `"Barrel"` (and any
turret-gun submesh) so the manning player sees their own weapon viewmodel, not a duplicate
turret barrel. Other players still see the full nest+barrel. Keep the third-person crouch/pose
logic (`_manned_ids`, `NEST_CROUCH_SCALE`) as-is.
**Validation:** controller screenshots first-person while manning (confirm no turret barrel
across the view) and a remote view of a manned nest (confirm barrel still present).

**6c — Fix bot nest sky-fire (bot AI, deterministic).**
`bots/exercisers.gd:710-747 drive_mounted_nest()` picks the nearest live enemy and fires,
computing pitch from seat→target (`:730`); with no valid target (e.g. at spawn) or a target
outside the turret arc, the clamped pitch pins to the up-limit and the bot fires into the sky.
Fix: only fire when a live enemy is (i) within the turret yaw arc (`half_arc_deg`), (ii) within a
sane max range, and (iii) within the allowed pitch band without pinning to the up-clamp; aim at
the target body. Otherwise HOLD FIRE (and optionally dismount after idling). Mirror the
"aim at a real target, not open sky" lesson from `nearest_wall_aim()` (`:835-861`) used by the
grapple bot. **TDD:** extend `tests/bot_lmg_nest_test.gd` — with no enemy / an out-of-arc enemy,
the bot does NOT fire; with an in-arc grounded enemy, it fires with a downward/level pitch (not
the up-clamp). Full suite green.

---

## Task 7 — M3: Rubble collision — no invisible prone camping (server sim)

**Problem:** after `server_main.gd:2583-2637 _collapse_building()` stamps `brubble` pieces over
the footprint, the rubble does NOT block at all. Owner confirmed (2026-07-13): **both bots and
the player run straight THROUGH rubble blocks in every stance** — no movement stop, no step-up
onto them, and you can lie/crouch inside them, invisible. So although `brubble` is
`height:"half", blocks:"both", structural:false` (`pieces/pieces.json:340-347`) — flags that
should block — the collapse-generated rubble has effectively NO collision. Root-cause WHY the
placed brubble pieces don't register as movement/LOS blockers (candidates: the piece is placed
but the resolver treats `structural:false` / half-height as non-blocking or vaultable-through;
the collapse stamps into a store/layer the movement resolver doesn't consult; owner id 0 or the
delta path drops them; or half-height `blocks:both` isn't wired into `_blocks_ground`). Root-cause this with
systematic-debugging BEFORE changing anything: reproduce whether a PRONE pawn can occupy a
brubble cell (movement resolver `structure.gd:350-384 _blocks_ground`/`resolve_movement`,
`is_tall_blocker` `:392-403`) and whether a prone target in a brubble cell is hidden from LOS —
i.e. is the exploit "collision lets me lie in the cell" or "the cosmetic rubble mound
(`building_kit.gd:240-248 build_rubble`) is taller/wider than the collision and visually swallows
me while I stand beside the low collision".

**Change (after root cause):** make collapse rubble deny the invisible-prone exploit while
staying BattleBit-style low cover (climbable/vaultable). Likely one of: (a) prone stance cannot
occupy/allow hiding in a brubble cell (treat brubble as blocking a prone body's cell), and/or
(b) align the cosmetic rubble mound extent with the actual brubble collision so what you see
matches what blocks. Do NOT make rubble a full-height wall (it should remain low cover you can
shoot over / vault). Keep it server-authoritative.
**TDD:** add/extend `tests/collapse_zone_test.gd` (or a new `rubble_collision_test.gd`) — after a
collapse, a pawn cannot be positioned prone-hidden inside a rubble cell (blocked or exposed);
rubble remains vaultable/low. Full suite green.

---

## Landing

After all tasks pass both reviews and the full suite is green: rebuild the native encoder
(`cargo build --release --manifest-path native/snapshot_encoder/Cargo.toml`) is NOT required
(no wire change) but the server must be restarted on the new code for the playtest. Reconcile
onto master, merge, push (AGENTS.md §11), then restart the game2 server + bots and launch a
fresh client for the owner. Update the M19/M20-adjacent memory + `docs/TASKS.md` (mark fixed
codes done). Deferred items remain in TASKS.md.
