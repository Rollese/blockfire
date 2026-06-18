# M7-P2 — Imported GLB Characters + Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render players with the Kenney **blocky GLB characters** and their built-in animations (idle / walk / sprint / die) instead of the procedural box soldier, behind a settings flag, with the procedural `CharacterKit` kept intact as the default fallback so every existing test stays green.

**Architecture:** Three new presentation-only factories under `client/art/` (AGENTS.md §7): `CharacterAnim` — a **pure** `state → clip` mapping (headless-unit-testable, the "brain"); `GlbCharacterKit` — loads/instantiates the GLB scene and **scales it to the sim's stand height** (1.8 m); `CharacterDriver` — plays the selected clip on the model's `AnimationPlayer`. The **only** edit to shared renderer code is `WorldRenderer`, which chooses the kit at `_make_entity_mesh()` and drives animation from a per-frame **speed estimate** (derived from position delta, since velocity isn't on the wire). Stance (crouch shrink / prone tip) keeps using the existing `_pose_entity` logic in v1. Visual quality is the **owner's playtest** (AGENTS.md §10); headless tests assert structure and mapping logic only.

**Tech Stack:** Godot 4.6 / GDScript. GLB assets already imported under `assets/characters/`. Tests: `godot --headless --path . -- --test [--filter=<substr>]`, classes extend the global `TestCase` (`tests/*_test.gd`).

**Supersession:** This supersedes the **character portion** of `docs/plans/2026-06-17-m7-p2-art-kit-procedural.md`, whose "Out of scope" forbade external meshes + animation. Weapons / vehicles / structures / props remain procedural per that plan; **only the player character** moves to an imported animated model. Task 0 records this. The choice (use the Kenney clips + author the gaps later, keep the BattleBit single-uniform + friendly-marker design) was owner-ratified 2026-06-18.

## GDScript / Godot gotchas (every task)
- After adding any new `class_name` script, run **`godot --headless --path . --import`** once before tests (don't pipe `godot` through `tail`/`head`; redirect to a file if needed).
- GDScript 4.6 rejects `var x := <Dictionary access>` (Variant) and `var x := <untyped call>` — annotate the type explicitly; don't change logic.
- The harness **fails any test that runs zero assertions** (catches compile-error false-passes), so every test must assert.
- `AnimationPlayer.play()` and `Animation.loop_mode` work headless (no render context needed) **once the node is inside a SceneTree** — tests add the instance under a temporary parent `Node`.
- `git add -A` to include Godot `.uid` sidecars in commits. Commit trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Sim / asset references (read-only — do not edit)
- `client/art/character_kit.gd`: `const STAND_HEIGHT := 1.8` (canonical render stand height; the renderer scales to it).
- `shared/sim/entity_state.gd`: fields `pos, yaw, pitch, stance, lean, team, alive, health, is_downed, climbing, squad`. **No velocity, no firing flag.**
- `shared/sim/stance.gd`: `Stance.STAND/CROUCH/PRONE`; `Stance.body_height(STAND)` ≈ 1.8, `CROUCH` 1.2, `PRONE` 0.5.
- GLB scene `res://assets/characters/character-a.glb` when instantiated: root `Node3D`, child `AnimationPlayer` at relative path `"AnimationPlayer"`, 27 clips incl. `idle walk sprint die holding-both holding-both-shoot pick-up sit` — all imported with `loop_mode = 0` (none loop).
- `client/world_renderer.gd`: swap seam `_make_entity_mesh()` (line ~460), per-frame `_pose_entity(node, es)` (line ~319), `update(...)` already receives `render_delta`.
- `client/settings.gd`: `class_name ClientSettings extends RefCounted`, ConfigFile sections `input`/`video`/`audio`.

## File map

| File | Create/Modify | Responsibility |
|---|---|---|
| `docs/plans/2026-06-17-m7-p2-art-kit-procedural.md` | Modify | Record that the character is superseded by this plan. |
| `client/art/character_anim.gd` | Create | Pure `clip_for(downed, speed, stance) -> {clip, loop}` mapping + speed thresholds. |
| `client/art/glb_character_kit.gd` | Create | Load/instantiate the GLB, scale to `STAND_HEIGHT`, expose its `AnimationPlayer`. |
| `client/art/character_driver.gd` | Create | Play a named clip (set loop) on an `AnimationPlayer` idempotently. |
| `client/settings.gd` | Modify | Add persisted `use_model_characters` flag. |
| `client/world_renderer.gd` | Modify | Choose kit behind `use_models`; derive per-id speed; drive animation. |
| `client/client_main.gd` | Modify | One line: pass `settings.use_model_characters` to the renderer after `setup()`. |
| `tests/art_character_anim_test.gd` | Create | Mapping unit tests. |
| `tests/art_glb_character_kit_test.gd` | Create | Build/scale/anim-player structure tests. |
| `tests/art_character_driver_test.gd` | Create | Driver play/loop tests. |
| `tests/client_settings_model_flag_test.gd` | Create | Flag persistence test. |

---

# Part 1 — Playable model swap (TDD)

### Task 0: Record the supersession

**Files:**
- Modify: `docs/plans/2026-06-17-m7-p2-art-kit-procedural.md`

- [ ] **Step 1: Add a banner under the plan's top header.** Insert this line immediately after the `**Goal:**` line of that file:

```markdown
> **SUPERSEDED (character only), 2026-06-18:** The player **character** is now an imported animated GLB model — see `docs/plans/2026-06-18-m7-p2-glb-characters.md`. Weapons, vehicles, structures, and props remain procedural per this plan. The "No external meshes / No animation" scope below applies to those remaining categories only.
```

- [ ] **Step 2: Commit** (doc-only, no test):

```bash
git add docs/plans/2026-06-17-m7-p2-art-kit-procedural.md docs/plans/2026-06-18-m7-p2-glb-characters.md
git commit -m "docs(m7-p2): supersede procedural character with imported GLB model plan"
```

---

### Task 1: `CharacterAnim` — pure state→clip mapping

**Files:**
- Create: `client/art/character_anim.gd`
- Test: `tests/art_character_anim_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/art_character_anim_test.gd`:

```gdscript
extends TestCase

func test_idle_when_still_and_alive() -> void:
	var r := CharacterAnim.clip_for(false, 0.0, Stance.STAND)
	assert_eq(r["clip"], "idle", "still -> idle")
	assert_true(r["loop"], "idle loops")

func test_walk_above_walk_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 1.5, Stance.STAND)
	assert_eq(r["clip"], "walk", "moderate speed -> walk")
	assert_true(r["loop"], "walk loops")

func test_sprint_above_sprint_threshold() -> void:
	var r := CharacterAnim.clip_for(false, 6.0, Stance.STAND)
	assert_eq(r["clip"], "sprint", "high speed -> sprint")

func test_downed_plays_die_pose_non_looping() -> void:
	var r := CharacterAnim.clip_for(true, 0.0, Stance.STAND)
	assert_eq(r["clip"], "die", "downed -> die collapse pose")
	assert_false(r["loop"], "die does not loop (holds last frame)")

func test_downed_overrides_movement() -> void:
	var r := CharacterAnim.clip_for(true, 6.0, Stance.STAND)
	assert_eq(r["clip"], "die", "downed wins over speed")
```

- [ ] **Step 2: Run, verify fail** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_character_anim`. Expected: FAIL (`CharacterAnim` not found).

- [ ] **Step 3: Implement** — `client/art/character_anim.gd`:

```gdscript
class_name CharacterAnim
extends Object
## Pure mapping: replicated render state -> Kenney clip name + whether it loops. No gameplay logic
## (AGENTS.md §7). Speed is the renderer's per-frame horizontal speed estimate in m/s (velocity is
## not on the wire). Crouch/prone *shape* stays in WorldRenderer._pose_entity (shrink/tip) for v1;
## this only selects the locomotion/idle/down clip. Returns {"clip": String, "loop": bool}.

const WALK_SPEED := 0.6     # m/s above which the figure is "moving"
const SPRINT_SPEED := 4.5   # m/s above which it is "sprinting"

static func clip_for(downed: bool, speed: float, _stance: int) -> Dictionary:
	if downed:
		return {"clip": "die", "loop": false}   # collapse pose; held at last frame
	if speed >= SPRINT_SPEED:
		return {"clip": "sprint", "loop": true}
	if speed >= WALK_SPEED:
		return {"clip": "walk", "loop": true}
	return {"clip": "idle", "loop": true}
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_character_anim`. Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add client/art/character_anim.gd client/art/character_anim.gd.uid tests/art_character_anim_test.gd tests/art_character_anim_test.gd.uid
git commit -m "feat(m7-p2): CharacterAnim pure state->clip mapping"
```

---

### Task 2: `GlbCharacterKit` — load, scale to sim height, expose AnimationPlayer

**Files:**
- Create: `client/art/glb_character_kit.gd`
- Test: `tests/art_glb_character_kit_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/art_glb_character_kit_test.gd`:

```gdscript
extends TestCase

func test_build_returns_node3d_with_animationplayer() -> void:
	var node := GlbCharacterKit.build()
	assert_true(node is Node3D, "build() returns a Node3D root")
	var ap := GlbCharacterKit.anim_player(node)
	assert_true(ap is AnimationPlayer, "exposes the model's AnimationPlayer")
	assert_true(ap.has_animation("walk"), "walk clip present")
	assert_true(ap.has_animation("idle"), "idle clip present")
	node.free()

func test_build_scales_model_to_stand_height() -> void:
	var node := GlbCharacterKit.build()
	var aabb := GlbCharacterKit.world_aabb(node)
	assert_true(absf(aabb.size.y - GlbCharacterKit.STAND_HEIGHT) < 0.05,
		"scaled height ~= STAND_HEIGHT (got %f)" % aabb.size.y)
	node.free()

func test_stand_height_matches_canonical() -> void:
	assert_eq(GlbCharacterKit.STAND_HEIGHT, CharacterKit.STAND_HEIGHT,
		"GLB stand height equals the procedural kit's so renderer scaling is mode-agnostic")
```

- [ ] **Step 2: Run, verify fail** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_glb_character_kit`. Expected: FAIL (`GlbCharacterKit` not found).

- [ ] **Step 3: Implement** — `client/art/glb_character_kit.gd`:

```gdscript
class_name GlbCharacterKit
extends Object
## Loads the imported Kenney blocky character and normalizes it for the renderer. Presentation-only
## (AGENTS.md §7). The model is a node-transform-animated hierarchy (no skeleton); we keep one
## variant (character-a) for everyone — BattleBit single-uniform rule; friend/foe is the marker the
## renderer floats above friendlies, never body colour. The instanced model is scaled so its
## standing height matches the procedural kit's STAND_HEIGHT, so WorldRenderer's stance scaling math
## is identical for both modes.

const SCENE_PATH := "res://assets/characters/character-a.glb"
const STAND_HEIGHT := 1.8   # must equal CharacterKit.STAND_HEIGHT

static func build() -> Node3D:
	var ps := load(SCENE_PATH) as PackedScene
	var inst := ps.instantiate() as Node3D
	# Normalize height: the raw model is authored at its own scale; fit its AABB height to STAND_HEIGHT.
	var raw := world_aabb(inst)
	if raw.size.y > 0.001:
		var s := STAND_HEIGHT / raw.size.y
		inst.scale = Vector3(s, s, s)
	return inst

## The model's AnimationPlayer (direct child of the instanced root).
static func anim_player(node: Node3D) -> AnimationPlayer:
	return node.get_node_or_null("AnimationPlayer") as AnimationPlayer

## Recursive union of every MeshInstance3D AABB, expressed in `root` local space. Headless-safe
## (mesh geometry only; no rendering context). Used to normalize height.
static func world_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var local: AABB = mi.mesh.get_aabb()
			# transform corners into root space via the relative transform
			var xf: Transform3D = root.global_transform.affine_inverse() * mi.global_transform \
				if mi.is_inside_tree() else _relative_xform(root, mi)
			var box := xf * local
			if first:
				out = box; first = false
			else:
				out = out.merge(box)
		for c in n.get_children():
			stack.append(c)
	return out

static func _relative_xform(root: Node3D, target: Node3D) -> Transform3D:
	# Compose transforms from target up to (but not including) root, when not yet in a SceneTree.
	var xf := Transform3D.IDENTITY
	var n: Node = target
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_glb_character_kit`. Expected: PASS (3 tests). If `test_build_scales_model_to_stand_height` fails on the tolerance, read the printed height and widen tolerance only if the model is legitimately near 1.8 (do not mask a broken AABB walk).

- [ ] **Step 5: Commit**

```bash
git add client/art/glb_character_kit.gd client/art/glb_character_kit.gd.uid tests/art_glb_character_kit_test.gd tests/art_glb_character_kit_test.gd.uid
git commit -m "feat(m7-p2): GlbCharacterKit load + height-normalize imported character"
```

---

### Task 3: `CharacterDriver` — idempotent clip playback

**Files:**
- Create: `client/art/character_driver.gd`
- Test: `tests/art_character_driver_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/art_character_driver_test.gd`:

```gdscript
extends TestCase

func _mounted() -> Array:
	# Build a model and mount it under a temporary parent so AnimationPlayer.play() works headless.
	var parent := Node.new()
	var model := GlbCharacterKit.build()
	parent.add_child(model)
	return [parent, model, GlbCharacterKit.anim_player(model)]

func test_drive_plays_requested_clip() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "walk", true)
	assert_eq((m[2] as AnimationPlayer).current_animation, "walk", "walk is current")
	(m[0] as Node).free()

func test_drive_sets_loop_mode() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "walk", true)
	var a := (m[2] as AnimationPlayer).get_animation("walk")
	assert_eq(a.loop_mode, Animation.LOOP_LINEAR, "loop requested -> LOOP_LINEAR")
	CharacterDriver.drive(m[2], "die", false)
	var d := (m[2] as AnimationPlayer).get_animation("die")
	assert_eq(d.loop_mode, Animation.LOOP_NONE, "no loop requested -> LOOP_NONE")
	(m[0] as Node).free()

func test_drive_unknown_clip_is_noop() -> void:
	var m := _mounted()
	CharacterDriver.drive(m[2], "does-not-exist", true)
	assert_true((m[2] as AnimationPlayer).current_animation != "does-not-exist", "unknown clip ignored")
	(m[0] as Node).free()

func test_drive_null_player_is_safe() -> void:
	CharacterDriver.drive(null, "walk", true)
	assert_true(true, "null AnimationPlayer does not crash")
```

- [ ] **Step 2: Run, verify fail** — `godot --headless --path . --import` then `godot --headless --path . -- --test --filter=art_character_driver`. Expected: FAIL (`CharacterDriver` not found).

- [ ] **Step 3: Implement** — `client/art/character_driver.gd`:

```gdscript
class_name CharacterDriver
extends Object
## Plays a named clip on a model's AnimationPlayer idempotently (no restart if already current).
## Presentation-only (AGENTS.md §7). Sets the clip's loop_mode each call so the same clip can be
## reused looped (walk) or one-shot (die).

static func drive(ap: AnimationPlayer, clip: String, loop: bool) -> void:
	if ap == null or not ap.has_animation(clip):
		return
	var a := ap.get_animation(clip)
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	if ap.current_animation != clip:
		ap.play(clip)
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=art_character_driver`. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add client/art/character_driver.gd client/art/character_driver.gd.uid tests/art_character_driver_test.gd tests/art_character_driver_test.gd.uid
git commit -m "feat(m7-p2): CharacterDriver idempotent clip playback"
```

---

### Task 4: `use_model_characters` settings flag

**Files:**
- Modify: `client/settings.gd`
- Test: `tests/client_settings_model_flag_test.gd`

- [ ] **Step 1: Write the failing test** — `tests/client_settings_model_flag_test.gd`:

```gdscript
extends TestCase

func test_flag_defaults_false() -> void:
	var s := ClientSettings.new()
	assert_false(s.use_model_characters, "default is the procedural kit (safe fallback)")

func test_flag_round_trips_through_configfile() -> void:
	var path := "user://test_model_flag.cfg"
	var a := ClientSettings.new()
	a.use_model_characters = true
	a.save_to(path)
	var b := ClientSettings.new()
	b.load_from(path)
	assert_true(b.use_model_characters, "flag persists across save/load")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
```

- [ ] **Step 2: Run, verify fail** — `godot --headless --path . -- --test --filter=client_settings_model_flag`. Expected: FAIL (no `use_model_characters`).

- [ ] **Step 3: Implement** — in `client/settings.gd`:

  Add the field after `renderer_fallback`:
```gdscript
var use_model_characters: bool = false   # true -> imported GLB soldier; false -> procedural CharacterKit
```
  In `save_to()`, add inside the `video` section writes:
```gdscript
	cf.set_value("video", "use_model_characters", use_model_characters)
```
  In `load_from()`, add alongside the other `video` reads:
```gdscript
	use_model_characters = bool(cf.get_value("video", "use_model_characters", use_model_characters))
```

- [ ] **Step 4: Run, verify pass** — `godot --headless --path . -- --test --filter=client_settings_model_flag`. Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add client/settings.gd tests/client_settings_model_flag_test.gd tests/client_settings_model_flag_test.gd.uid
git commit -m "feat(m7-p2): persisted use_model_characters settings flag"
```

---

### Task 5: Wire the model + animation into `WorldRenderer` behind the flag

**Files:**
- Modify: `client/world_renderer.gd`
- Modify: `client/client_main.gd`

- [ ] **Step 1: Add the mode flag + speed-tracking state.** In `client/world_renderer.gd`, after the `_free_list` declaration (~line 38) add:

```gdscript
# Character render mode: false = procedural CharacterKit (default), true = imported GLB model.
var use_models: bool = false
# Per-id last position + AnimationPlayer, for the per-frame speed estimate that selects the clip.
var _last_pos: Dictionary = {}        # id(int) -> Vector3
var _entity_ap: Dictionary = {}       # id(int) -> AnimationPlayer (only when use_models)
```

- [ ] **Step 2: Make the swap seam honor the flag.** Replace `_make_entity_mesh()` (~line 460):

```gdscript
func _make_entity_mesh() -> Node3D:
	# Soldiers share one uniform (no team tint); friend/foe is the marker above the head.
	if use_models:
		return GlbCharacterKit.build()
	return CharacterKit.build()
```

- [ ] **Step 3: Cache the AnimationPlayer on acquire, drop it on release.** In `_acquire_entity(id)`, just before `return node` at the end of the create-or-reuse path, add:

```gdscript
	if use_models and not _entity_ap.has(id):
		_entity_ap[id] = GlbCharacterKit.anim_player(node)
```
  And in `_release_entity(id)`, after `_active.erase(id)`, add:

```gdscript
	_entity_ap.erase(id)
	_last_pos.erase(id)
```

- [ ] **Step 4: Thread `render_delta` to the entity pass.** Change the call in `update(...)` (~line 148) from `_sync_entity_pool(remotes, local_team)` to:

```gdscript
	_sync_entity_pool(remotes, local_team, render_delta)
```
  Change the signature of `_sync_entity_pool` to:

```gdscript
func _sync_entity_pool(remotes: Dictionary, local_team: int, render_delta: float) -> void:
```
  Inside it, change the pose call `_pose_entity(node, es)` to `_pose_entity(int(id), node, es, render_delta)`.

- [ ] **Step 5: Drive animation from a speed estimate inside `_pose_entity`.** Change the signature and add the animation block at the **top** of `_pose_entity` (keep all existing positioning/tip/scale logic unchanged below it):

```gdscript
func _pose_entity(id: int, node: Node3D, es: EntityState, render_delta: float) -> void:
	if use_models:
		# Horizontal speed estimate from frame-to-frame position (velocity isn't replicated).
		var last: Vector3 = _last_pos.get(id, es.pos)
		var dt: float = maxf(render_delta, 0.0001)
		var flat := Vector3(es.pos.x - last.x, 0.0, es.pos.z - last.z)
		var speed: float = flat.length() / dt
		_last_pos[id] = es.pos
		var sel: Dictionary = CharacterAnim.clip_for(es.is_downed, speed, es.stance)
		CharacterDriver.drive(_entity_ap.get(id) as AnimationPlayer, sel["clip"], sel["loop"])
	# --- existing positioning logic below, unchanged ---
	var pose: Dictionary = StancePose.of(es.stance, es.lean, es.is_downed, es.climbing)
	# ... (rest of the original _pose_entity body stays exactly as-is) ...
```

- [ ] **Step 6: Pass the flag from `client_main`.** Find the renderer setup call: `grep -n "_renderer.setup\|\.setup(" client/client_main.gd`. Immediately after the `_renderer.setup(...)` line, add:

```gdscript
	_renderer.use_models = _settings.use_model_characters
```
  (Match the actual settings variable name from the grep — it may be `_settings` or `settings`.)

- [ ] **Step 7: Import + run the full unit suite.** Run:

```bash
godot --headless --path . --import > /tmp/imp.log 2>&1; tail -3 /tmp/imp.log
godot --headless --path . -- --test > /tmp/units.log 2>&1; tail -5 /tmp/units.log
```
  Expected: import clean; full suite **run > 0 / failed 0** (the new tests plus all pre-existing ones; the procedural path is untouched so nothing regresses).

- [ ] **Step 8: Commit**

```bash
git add client/world_renderer.gd client/client_main.gd
git commit -m "feat(m7-p2): render imported GLB soldier + locomotion anim behind use_models flag"
```

---

### Task 6: Headless smoke + enable the flag for the owner playtest

**Files:** none (verification + a local settings toggle the owner flips)

- [ ] **Step 1: ≤48-bot smoke gate** (proves the server-side path and that the renderer module still loads):

```bash
bash ci/m5_p1_test.sh > /tmp/smoke.log 2>&1; tail -15 /tmp/smoke.log
```
  Expected: PASS (valid winner, peak tick < 33.3 ms). The renderer change is client-only; this confirms no shared/test breakage.

- [ ] **Step 2: Owner playtest (manual, the real gate — AGENTS.md §10).** The owner enables the model in `user://settings.cfg` (`[video] use_model_characters=true`) or via the settings menu if exposed, then runs the client per `docs/runbooks/running-client.md` and confirms: soldiers render as Kenney models, idle when still, walk/sprint when moving, collapse when downed, sit/lie correctly for crouch/prone (shrink/tip), and the blue friendly marker still floats above teammates. Record sign-off + any feel notes in `docs/milestones/M7-art-ux.md`.

- [ ] **Step 3: Commit any doc/sign-off update.**

```bash
git add docs/milestones/M7-art-ux.md
git commit -m "docs(m7-p2): owner sign-off on imported GLB characters"
```

---

# Part 2 — Refinements (deferred; each needs a new signal — do NOT bundle into Part 1)

These are tracked follow-ups, not Part-1 blockers. Each is gated on a new input the v1 swap deliberately does not have. Implement only when scheduled, each via the same TDD loop.

- [ ] **Authored crouch / prone poses.** v1 reuses `_pose_entity`'s vertical shrink (crouch) and 90° tip (prone). For a nicer blocky read, author dedicated clips by keying the `leg-left/right` + `torso` node transforms (bend knees / lower torso for crouch; lay flat for prone) and select them in `CharacterAnim.clip_for` by `stance`. Needs new `Animation` resources baked in code or a small `.tscn`; assert clip presence + target tracks in a headless test. **No new wire data** (stance is already replicated) — this can be done any time.
- [ ] **Remote fire animation (`holding-both-shoot`).** Requires attributing a shot to an entity. Today `SHOT_FX` carries only `origin+dir` (`shared/net/protocol.gd:317`). Add a `shooter_id` to `encode_shot_fx`/`decode_shot_fx`, plumb it through `client_main`'s `SHOT_FX` handler to a renderer hook that one-shots `holding-both-shoot` on that id's AnimationPlayer (overriding locomotion briefly). **Protocol change → spec/ADR touch (AGENTS.md §5); coordinate as a netcode task.**
- [ ] **Reload animation (`pick-up` stand-in).** Local player: trigger off `WeaponPredictor` reload start. Remotes: needs a replicated reload bit (not on the wire today) — defer with fire above.
- [ ] **Jump.** No airborne flag is replicated; would need an `EntityState` bit or a derived vertical-velocity estimate. Lowest priority; defer until a jump state exists.
- [ ] **Team / squad variants.** 18 color variants are available; v1 uses one (BattleBit uniform). If the design later wants subtle squad differentiation, select a variant in `GlbCharacterKit.build(variant)` — but confirm against the single-uniform rule first.

---

## Self-Review

**Spec coverage:**
- "Integrate Kenney GLB + 27 animations behind a flag" → Tasks 2, 4, 5. ✅
- "Author missing crouch/prone/reload/jump" → v1 covers crouch/prone via existing `_pose_entity` shrink/tip; dedicated authored poses + reload/jump are Part 2 (each needs a signal v1 lacks — honestly scoped, not silently dropped). ✅
- "Keep BattleBit single-uniform + friendly-marker" → one variant in `GlbCharacterKit`; friendly-marker code untouched; noted in Task 5 Step 2 + Part 2. ✅
- "Map replicated state → clips" → `CharacterAnim` (Task 1) + speed derivation (Task 5 Step 5). ✅
- "Coexist with procedural CharacterKit as fallback; existing tests stay green" → flag defaults false, seam branches, procedural path untouched, Task 5 Step 7 + Task 6 Step 1 verify. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows full code; the one grep (Task 5 Step 6) is because the call-site variable name must be read from the actual file, with the exact line to add. ✅

**Type consistency:** `clip_for(downed, speed, stance) -> Dictionary{clip,loop}` used identically in Task 1 and Task 5 Step 5. `GlbCharacterKit.build()/anim_player()/world_aabb()/STAND_HEIGHT` consistent across Tasks 2/3/5. `CharacterDriver.drive(ap, clip, loop)` consistent in Tasks 3/5. `use_models` (renderer) vs `use_model_characters` (settings) are deliberately different names — the bridge is the one line in Task 5 Step 6. ✅
