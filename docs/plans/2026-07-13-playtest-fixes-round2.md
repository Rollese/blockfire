# Playtest fixes — round 2 (2026-07-13)

Owner ran a second laptop playtest of the round-1 fix build. Confirmed OK: A4 (fixed size),
M3 (rubble blocks), Z1 exterior z-fighting gone. This plan covers the remaining feedback +
two new bugs. Executed via subagent-driven-development in worktree `bf-playtest2`
(branch `playtest-fixes-round2`, based on `origin/master` @ aa5ab0b). No wire/VERSION change
in any task (native `.so` stays valid).

Root causes for the three "investigate" items were established by read-only investigators
first (systematic-debugging Iron Law) and are quoted per-task below.

---

## Task A — A4: loadout window closes itself (bug)

**Root cause (confirmed):** the loadout editor (`ClassSelectPanel`) is a child overlay of the
deploy menu. `DeployMenu.populate()` unconditionally force-hides it (`deploy_menu.gd:103-107`).
`populate()` re-runs whenever `_deploy_menu_populated` is reset to false, and one reset trigger
is a **FOB_LIST content change** (`client_main.gd:1529-1532`) — a teammate's FOB being
built/destroyed/toggled while the player lingers on the deploy screen editing their loadout.
The next snapshot repopulates and yanks the editor shut. Intermittent because FOB churn is
async to the player.

**Fix:** decouple "rebuild spawn buttons" (data refresh, which FOB_LIST legitimately needs)
from "reset loadout overlay to closed" (should only happen when the death/deploy screen freshly
appears).
1. `client/menus/deploy_menu.gd`: remove the force-hide inside `populate()` (lines ~103-107).
   Add an explicit `func close_loadout_editor() -> void:` that sets `_class_select.visible = false`.
2. `client/client_main.gd`: at the alive→dead transition where `_deploy_menu_populated` is reset
   (line ~1641), call `_deploy_menu.close_loadout_editor()` so a fresh death screen still starts
   with the editor closed.

**Keep intact:** Loadout button still opens it (`_on_loadout_btn_pressed`), Done button still
closes it via the `closed` signal, editor still starts closed on each new deploy screen. No test
asserts `populate()` hides the editor.

**Test:** unit-level — a test that `populate()` no longer changes editor visibility, and that
`close_loadout_editor()` hides it. (Behavioral: FOB_LIST refresh mid-edit no longer closes it.)

---

## Task B — Bug 2: tracers shoot through all walls (bug)

**Root cause (confirmed):** the tracer is a fixed **80 m box** drawn straight down the aim vector
and **never clipped to the bullet's impact point**, so it literally extends through any wall.
Render-state is correct (normal depth-test; it *would* be occluded if it ended at the wall).
- `client/world_renderer.gd:48` `const TRACER_LEN := 80.0`
- `client/world_renderer.gd:775` `tmesh.size = Vector3(0.06, 0.06, TRACER_LEN)`
- `client/world_renderer.gd:1150-1161` `_spawn_tracer` centres the 80 m box with no structure march.
Both local (`fire_tracer`) and remote (`tracer_from`) paths funnel through `_spawn_tracer`.

**Fix:** clip the tracer length to the first structure/terrain hit in `_spawn_tracer`, using the
already-synced client structure mirror `_fx.struct_store` and its hole-aware
`march(origin, dir, max_dist)` (`shared/sim/structure.gd:244-287`, same store the grenade
cosmetics already use). Scale the pooled node's basis Z by `length/TRACER_LEN` so no stale length
leaks between reuses; fall back to full length when `struct_store` is null. Client-only, no wire
change.

**Test:** unit — a helper that computes clipped tracer length from a stubbed march result returns
`min(TRACER_LEN, hit_dist)` on hit and `TRACER_LEN` on miss / null store.

---

## Task C — G1: grapple rope is 1px thin (cosmetic)

**Root cause:** `client/fx/grapple_rope.gd` `_redraw()` emits a `PRIMITIVE_LINE_STRIP` — a
1-pixel GPU line — so the rope is barely visible regardless of distance.

**Fix:** render the verlet chain as real tube geometry with a visible radius (~0.035–0.05 m).
Build a low-poly extruded tube (e.g. 5–6 radial sides) around the polyline in `_redraw()` using
`PRIMITIVE_TRIANGLES`/`TRIANGLE_STRIP` with proper normals so it shades. Keep the verlet sim, the
near/far sim gating, and the existing dark-rope material. Keep it cheap (guarded for many ropes at
128p — the existing SIM_RANGE static-line fallback still applies).

**Test:** unit — `_redraw()` (or an extracted tube-builder) produces a mesh with > 2 vertices per
segment ring (proves it's a tube, not a line) for a given point set.

---

## Task D — G2: shield viewmodel too tall + no see-through window (cosmetic)

**Owner feedback:** shield covers the top of the view (can't see sky above) and has no window to
look through. Wants a **tactical riot shield**: shorter (so the sky/above is visible) with a
**transparent viewport window in the middle** the player looks through. Functionality already
verified OK. (The lingering cosmetic "riot shield" wording elsewhere is deferred to a later
graphical-polish phase — note it in TASKS.md, don't chase it here.)

**Fix (client/world_renderer.gd `build_shield_viewmodel` + the `SHIELD_VM_*` consts):**
1. Reduce overall height so the top of the screen (sky) stays visible — lower `SHIELD_VM_SIZE.y`
   and/or drop the holder via `SHIELD_VM_OFFSET.y` so the plate sits lower in the view.
2. Replace the single opaque plate with a **frame** (top/bottom/left/right bars) leaving a
   rectangular hole in the **centre**, and fill that hole with a genuinely **transparent** glass
   panel (low-alpha, like the existing `_glass` window material) so the player sees through it.
   Remove/relocate the old near-top "Slit" (it's in the wrong place now).
Keep it first-person/local-only, geometry built statically so it stays unit-testable, and keep
the visibility gate (`_shield_up` and not photo/downed hidden).

**Test:** unit — `build_shield_viewmodel()` returns a node whose central window mesh uses a
transparent material (alpha < 1) and whose overall height is below the previous value.

---

## Task E — M1: bandage HUD is green text, wants a glyph + white number (cosmetic)

**Owner feedback:** replace the green `"BANDAGES xN"` font text with a **graphical bandage glyph
and a number in white** (consistent with the rest of the UI).

**Fix (client/hud/hud_view.gd, `_build_bandage_label` / `_render_bandage`):** replace the single
green Label with a small horizontal cluster: a custom-drawn **bandage icon** (a `Control` with
`_draw()` — a rounded plaster/adhesive-bandage shape with a centre pad, or a white medical cross
on a rounded rect) plus a **white** count Label (`"xN"`, white font, black outline to match other
HUD numbers). Keep the bottom-right anchor/position, keep hidden at count 0. Match the existing
HUD number style (white `font_color`, outline). No new image assets — draw procedurally.

**Test:** unit — the bandage cluster is hidden at 0, shown at >0, the count label text is `"xN"`
(no "BANDAGES" word), and its font color is white.

---

## Task F — Z1: gaps between individual roof floor slabs (bug from round-1 fix)

**Owner feedback:** the round-1 `ROOF_FLOOR_INSET=0.02` fix removed exterior wall/roof
z-fighting (good) but now there are **visible gaps between the individual roof floor slabs**
(each slab shrank by 0.02, so adjacent interior slabs no longer meet). Exactly the interior-seam
regression the round-1 reviewer flagged.

**Root cause:** `client/art/building_kit.gd` shrinks every `bfloor`/skirt slab uniformly to
`CELL - ROOF_FLOOR_INSET` (lines ~50, ~61). Interior shared edges between adjacent slabs are
opposite-facing and never z-fought, but the uniform shrink opens a 0.02 gap on every one of them.

**Fix:** restore slab-to-slab adjacency (no interior gaps) while keeping the exterior z-fight
fixed. Preferred approach: **oversize** the floor/skirt footprint slightly (e.g. `CELL + eps`,
eps ~0.02–0.04) instead of undersizing it — adjacent interior slabs then overlap invisibly (no
gap), and each perimeter slab's outer vertical face is **buried inside the wall** (wall exterior
face sits further out) instead of coplanar with it, so no z-fight. The implementer must first
VERIFY the wall geometry/offset (wall thickness ~0.3 centred on the cell boundary) to confirm an
`eps` that buries the edge without poking through the wall's outer face, and that open roof edges
(no wall) don't get an ugly overhang — if oversize risks an overhang, fall back to a tiny
**vertical** offset that breaks coplanarity instead. Collision (server cell-base plane) stays
untouched. Update the `ROOF_FLOOR_INSET` comment/const to reflect the real fix.

**Test:** update/extend the existing skirt/floor footprint test to assert adjacent slabs meet or
overlap (no positive gap) at the shared edge, and that the exterior edge does not sit exactly on
the wall exterior plane.

---

## Task G — G3: LMG nest looks bad — sandbag emplacement redesign (cosmetic, "dispatch a good agent")

**Owner feedback (verbatim intent):**
- The nest colour + pixelated texture should read as **sandbags**.
- It is **not tall enough** — it doesn't even cover a prone soldier (the gunner is force-prone).
- **Can't see out** — need an empty **"window"/embrasure** the gunner looks and shoots out of.
- Sandbags in a **curved quarter-circle** wrapping around the gunner.
- The **gun turret** (the mounted MG mesh) should be **removed** — the gunner shoots their own gun.

**Current state:** `client/art/lmg_nest_kit.gd` builds a low straight sandbag berm (front 1.6×0.5
+ two 0.8-deep returns), a tripod Mount post, and a "Barrel" child holding Receiver/Gun/Stock.
The renderer (`world_renderer.gd set_emplacements`, ~3627-3705) orients the body to facing,
rotates "Barrel" to the gunner's turret aim, tints the sandbag body by HP, and already hides the
Barrel for the LOCAL gunner (`nest_barrel_visible`).

**Fix:**
1. Redesign `LmgNestKit.build()` as a **curved quarter-circle sandbag emplacement**: stacked
   sandbag blocks arranged along an arc wrapping the gunner's firing side (front + partial sides),
   built tall enough to cover a **prone** gunner's body, with a **firing embrasure** (a gap in the
   sandbag courses) at the front-centre at the gunner's mounted **eye/muzzle height** so he can see
   and shoot out. The embrasure should align with the server facing (+Z forward) and the mounted
   view height — the implementer MUST read the mount/prone view height (`Emplacement`/
   `emplacement_server.gd` `MUZZLE_UP`, and the client mount camera height in `client_main.gd`)
   and place the gap there, not guess.
2. **Sandbag material:** a sandy/pixelated look — use `ArtPalette` sand tone + the pixelated/NEAREST
   texture path other structures use (see `structure_kit.gd` "sandbag" + the `_box(..., tex)`
   texture arg used in `building_kit.gd`). Keep it team-tintable/HP-darkenable so the existing
   `_tint_emplacement_hp` walk still works (it re-tints the body meshes, skipping "Barrel").
3. **Remove the gun turret:** drop the `Barrel`/Receiver/Gun/Stock assembly (and the tripod Mount
   post if it now reads as turret hardware). Update `world_renderer.gd set_emplacements` so the
   `Barrel`-lookup path no-ops gracefully when absent (guard the `get_node_or_null("Barrel")`
   traverse + the `nest_barrel_visible` call), and drop/repurpose the traverse rotation. Keep the
   HP-tint walk working on the new sandbag meshes.
4. Ensure the whole thing still reads correctly at the deploy facing and doesn't clip the
   force-prone gunner's camera (the embrasure must frame his view, not block it).

**This touches presentation only** (AGENTS.md §7) — no sim/collision/wire change. The nest's
gameplay collision/mount is server-side and unchanged.

**Test:** unit — `LmgNestKit.build()` returns a node with (a) no "Barrel"/gun child, (b) sandbag
meshes present, (c) an embrasure gap (front-centre has no occluding mesh across the eye-height
band). Plus `world_renderer` guards don't crash when "Barrel" is absent.

---

## Task H — Bug 1: invisible walls block shots inside buildings (bug)

**Root cause (confirmed, empirically verified by running the shipping classes headless):**
`bfloor` (and any `surface:true` flat piece) collides against bullets as a **full 2.4 m-tall
solid cube** in the ray path, but renders as a ~0.32 m thin slab — so the ~2 m of open air above
every floor tile is an **invisible bullet-blocker**. The LOS chokepoint is
`shared/sim/structure.gd` `_ray_piece()` (~lines 318-322): it builds the piece AABB top as
`mn.y + _face_height(type)`, which for a `full`-height piece is the entire 2.4 m cell — done for
EVERY type including floors. `march()` (~259-287) then blocks on that AABB. Movement exempts
floors (`_blocks_ground()` returns false for `is_flat_surface`, ~line 373) but LOS/`march()` has
**no** such exemption — hence walk-through-but-shoot-blocked. Bites upper-storey decks (every
upstairs spot blocks eye-height shots) and sparse ground-floor accent `bfloor` tiles ("certain
locations").

**Fix:** in `shared/sim/structure.gd` `_ray_piece()`, cap the AABB top for `is_flat_surface`
pieces to a thin horizontal slab. Add a const (e.g. `FLOOR_COLLISION_THICK := 0.35`) and when
`_catalog.is_flat_surface(type)` use `mn.y + FLOOR_COLLISION_THICK` instead of
`mn.y + _face_height(type)`. This keeps floors blocking VERTICAL LOS (can't shoot between building
levels — the ray still crosses the thin slab at the cell base) while horizontal shots at
stand/crouch/prone eye height (≥0.45 m above base) pass over it, and it fixes "can't fire while
standing on the deck."

**Do NOT:** change `_face_height()` (feeds chunk-mask V-mapping, vault heights, carving —
breaking destruction/vaulting); exempt `surface` pieces from `march()` entirely (would let bullets
pass vertically through floors — cover regression); touch `_blocks_ground` (movement already
correct); touch `passable`/doors or non-surface `brubble` (their blocking is intended);
touch `bstair` ramps (full-cell AABB plausibly intended — out of scope). `is_alive_at` must still
receive the full `_face_height` for chunk mapping (hole-aware carving unaffected).

**Test:** unit against the real `StructureStore` — place a `bfloor` cell (full chunk mask), fire a
horizontal ray at stand/crouch/prone eye height across/above it → NOT blocked; fire a vertical ray
down through it → still blocked; confirm `is_alive_at`/chunk carving unchanged. (The investigator's
repro harness fired stand=4.0/crouch=3.5/prone=2.85 eye heights and all wrongly hit at dist 0.0
pre-fix.)

---

## Integration / landing

Run the full suite in the worktree after each task (`godot --headless --path . -s tests/run_tests.gd`
or the project runner). Native-encoder tests need the `.so` (present in worktree). After all tasks:
final review, commit each task atomically, reconcile → merge to master → push, restart the game2
server on the new master, notify owner for re-playtest. Update `docs/TASKS.md` + memory.
