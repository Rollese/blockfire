# Lighting & Post-FX Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the client to golden-hour BattleBit atmosphere by enabling and tuning Forward+ lighting/post-processing (currently all off) plus a game-wide NEAREST texture filter — client-only presentation.

**Architecture:** Effects live as data in `client/client.tscn` (Environment sub-resource, Sky, DirectionalLight). The NEAREST filter is applied in `client/art/*` (a shared runtime helper walks GLB materials; procedural kits set it inline). Per-pixel effects (glow/SSAO/volumetric) are GPU-tier-bound, not player-count-bound, so they don't touch the tick or fleet gate. Forward+-only effects (SSAO, volumetric fog) no-op gracefully on the GL-Compatibility fallback.

**Tech Stack:** Godot 4.7, GDScript, Forward+ renderer (+ gl_compatibility fallback). Reference spec: `docs/superpowers/specs/2026-07-07-lighting-postfx-pass-design.md`.

---

## Working agreement for every task

- **Branch:** `lighting-postfx-pass` (already created). Commit per task.
- **Suite must stay green:** `godot --headless --path . -- --test` → expect `TESTS: <n> run, 0 failed` (baseline **1379/0**; increment 0 adds tests → count rises).
- **Client-only:** never edit `shared/`, `server/`, wire, or tick code. If a task seems to need that, STOP and flag.
- **Visual increments (Tasks 5–9) are validated on a real GPU, not by unit tests.** The deterministic guarantee is "suite green"; the *quality* bar is the owner's real-GPU A/B sign-off. **Do not claim a visual increment done until the owner signs off the A/B.** Colour/exposure/AO are untrustworthy on llvmpipe/GL-compat/xvfb (AGENTS.md §10).

### Real-GPU A/B loop (referenced by Tasks 5–9)

Two options; the owner chose the **live client on .194**. A faster standalone alternative is noted.

**Standalone (fast, static): `tools/render_town_shots.gd`** instantiates `client.tscn` — so it *does* reflect Environment edits (unlike the foliage preview, which builds its own env). Use for quick single-frame A/Bs on a real GPU:
```bash
rsync -a --delete --exclude '.godot' ~/projects/blockfire/ roland@192.168.1.194:~/bf-lighting/
ssh roland@192.168.1.194 'bash -lc "cd ~/bf-lighting && godot --headless --import ."'
ssh roland@192.168.1.194 'bash -lc "cd ~/bf-lighting && setsid env WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 godot --path . tools/render_town_shots.gd >/tmp/bf-shot.log 2>&1 </dev/null & disown"'
# pull PNGs the harness writes (grep the harness for its output dir), study locally / send to owner
```

**Live client (highest fidelity, owner's choice):** server+bots on game2 (this dev host) in tmux, rendered client onto the .194 KDE-Wayland desktop:
```bash
# server (local game2):
tmux new-session -d -s bf-server 'cd ~/projects/blockfire && godot --headless --path . -- --server --port=27015 2>&1 | tee /tmp/bf-server.log'
tmux new-session -d -s bf-bots   'cd ~/projects/blockfire && godot --headless --path . -- --bots --bot-count=8 --connect=127.0.0.1 --port=27015 2>&1 | tee /tmp/bf-bots.log'
# client (.194), fixed HQ spawn + auto-screenshot then quit:
ssh roland@192.168.1.194 'bash -lc "cd ~/bf-lighting && setsid env WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 godot --path . -- --connect=192.168.1.166 --port=27015 --deploy=0 --shot-after=8 --name=Roland >/tmp/bf-client.log 2>&1 </dev/null & disown"'
```
- `--deploy=0` = HQ auto-spawn (faces south; good for a low-sun sky/bloom vantage). For an in-town SSAO vantage, deploy onto an alive team-0 squadmate: `--deploy=<201/203/205/207/209>` (see `blockfire-m7-lighting-environment`).
- `--shot-after=N` saves one screenshot N s after launch then quits (`client/client_main.gd:169,221,683`). Screenshots land where `_save_screenshot()` writes — grep `client/client_main.gd:625` for the path; pull them with scp.
- Server exits at match-end (~11.5 min bot bleed); (re)start fresh per session.
- **A/B method:** capture "before" from current `master` build first, then "after" from the branch build at the *same* vantage/spawn. Send both to the owner.

**Compatibility check (once, after Task 8):** relaunch the live client with `renderer_fallback=true` (set in the client's `settings.cfg` `[video] renderer_fallback=true`, or the laptop .116) and confirm the scene still renders (sky+sun+fog+glow present; SSAO/volumetric simply absent) with no errors in `/tmp/bf-client.log`.

---

## Increment 0 — Game-wide NEAREST texture filter (both renderers, no perf risk)

### Task 1: Shared NEAREST filter helper

**Files:**
- Create: `client/art/art_filter.gd`
- Test: `tests/art_filter_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/art_filter_test.gd
extends TestCase   # repo harness (see tests/art_foliage_kit_test.gd): assert_eq/assert_ne/assert_gt, func setup()

func test_apply_nearest_sets_filter_on_mesh_materials() -> void:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mi.material_override = mat
	root.add_child(mi)
	var n := ArtFilter.apply_nearest(root)   # ArtFilter is global via class_name (no preload)
	assert_gt(n, 0, "at least one material switched")
	assert_eq(mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "override material is NEAREST")
	root.free()

func test_apply_nearest_walks_surface_override_materials() -> void:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mi.set_surface_override_material(0, mat)
	root.add_child(mi)
	ArtFilter.apply_nearest(root)
	assert_eq(mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "surface override material is NEAREST")
	root.free()
```

> The repo harness is a custom `TestCase` base (asserts: `assert_eq(actual, expected, msg)`, `assert_ne`, `assert_gt`; setup hook is `func setup()`). Kits/helpers with `class_name` are globally available — no `preload`/`const`.

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "art_filter|FAIL|error"`
Expected: FAIL — `art_filter.gd` does not exist / `apply_nearest` not defined.

- [ ] **Step 3: Write minimal implementation**

```gdscript
# client/art/art_filter.gd
class_name ArtFilter
extends Object
## Walk a built node tree and force every mesh material to NEAREST texture filtering,
## for the game-wide pixel-cutout look. Client-only presentation (AGENTS.md §7).
## Procedural kits set the filter inline at creation; this helper is for GLB-loaded
## models whose materials are baked LINEAR by the glTF importer.

## Returns the number of materials switched. Idempotent.
static func apply_nearest(root: Node) -> int:
	var count := 0
	for node in _iter(root):
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.material_override is BaseMaterial3D:
				(mi.material_override as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				count += 1
			var surfaces := 0
			if mi.mesh != null:
				surfaces = mi.mesh.get_surface_count()
			for s in surfaces:
				var m := mi.get_surface_override_material(s)
				if m == null and mi.mesh != null:
					m = mi.mesh.surface_get_material(s)
				if m is BaseMaterial3D:
					(m as BaseMaterial3D).texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
					count += 1
	return count

static func _iter(root: Node) -> Array:
	var out: Array = [root]
	for c in root.get_children():
		out.append_array(_iter(c))
	return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "art_filter|TESTS:"`
Expected: PASS; `TESTS: <n> run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add client/art/art_filter.gd tests/art_filter_test.gd
git commit -m "feat(art): ArtFilter.apply_nearest helper for game-wide pixel filtering

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 2: Procedural building materials → NEAREST

**Files:**
- Modify: `client/art/building_kit.gd:185` and `client/art/building_kit.gd:218`
- Test: `tests/building_kit_filter_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/building_kit_filter_test.gd
extends TestCase

func test_textured_building_material_is_nearest() -> void:
	# Build a textured wall piece and assert its material filters NEAREST.
	# Use the same entry point world_renderer uses; inspect the returned MeshInstance3D.
	var mi := BuildingKit.wall(Vector3(4, 3, 0.3), Vector3.ZERO, "brick", 0)  # adjust to real signature
	assert_ne(mi.material_override, null, "wall has a material")
	assert_eq((mi.material_override as BaseMaterial3D).texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST, "wall material is NEAREST")
	mi.free()
```

> Open `client/art/building_kit.gd` and use the **actual** function name/signature that produces the textured piece at line 185 (the test above is illustrative — match reality). If the textured builder isn't a clean static entry point, add the assertion against whatever `world_renderer` calls.

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "building_kit_filter|FAIL"`
Expected: FAIL — filter is `LINEAR_WITH_MIPMAPS` (the default), not NEAREST.

- [ ] **Step 3: Write minimal implementation**

In `client/art/building_kit.gd`, after `mat.albedo_texture = BuildingTextures.tex(tex)` (line ~185) add:
```gdscript
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # game-wide pixel look
```
And in the metal-material builder, after `mat.albedo_texture = BuildingTextures.tex("metal")` (line ~218) add the same line:
```gdscript
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
```

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "building_kit_filter|TESTS:"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/art/building_kit.gd tests/building_kit_filter_test.gd
git commit -m "feat(art): building materials use NEAREST filter (game-wide pixel look)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 3: Apply NEAREST to GLB-loaded kits

**Files:**
- Modify: `client/art/glb_weapon_kit.gd` (after `ps.instantiate()`, ~line 34)
- Modify: `client/art/glb_character_kit.gd` (after `ps.instantiate()`, ~line 26)
- Modify: `client/art/menu_art.gd` (after any GLB instantiate — only if it renders a 3D GLB model)
- Test: `tests/glb_kit_filter_test.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
# tests/glb_kit_filter_test.gd
extends TestCase

func test_glb_weapon_model_materials_are_nearest() -> void:
	var model := GlbWeaponKit.build(Weapon.AR)   # match real entry point / arg type
	assert_ne(model, null, "weapon model built")
	# Every BaseMaterial3D in the built model must be NEAREST.
	var bad := 0
	for n in _all(model):
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.material_override is BaseMaterial3D and (mi.material_override as BaseMaterial3D).texture_filter != BaseMaterial3D.TEXTURE_FILTER_NEAREST:
				bad += 1
	assert_eq(bad, 0, "no GLB material left non-NEAREST")
	model.free()

func _all(root: Node) -> Array:
	var out: Array = [root]
	for c in root.get_children():
		out.append_array(_all(c))
	return out
```

> Match `GlbWeaponKit`'s real build function + weapon-id type by reading `client/art/glb_weapon_kit.gd`. If GLB materials are surface materials (not overrides), also check `surface_get_material` — but since Task 1's helper handles both, the assertion should pass once the helper is called.

- [ ] **Step 2: Run test to verify it fails**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "glb_kit_filter|FAIL"`
Expected: FAIL — GLB materials import as LINEAR by default.

> If the headless GLB import produces `null`/no materials in this environment, keep the test but gate it to skip when the model has zero materials, and rely on the real-GPU check. Note this in the commit.

- [ ] **Step 3: Write minimal implementation**

In `client/art/glb_weapon_kit.gd`, right after `var model := ps.instantiate() as Node3D`:
```gdscript
	ArtFilter.apply_nearest(model)   # game-wide pixel look on GLB weapon textures
```
Add `const ArtFilter = preload("res://client/art/art_filter.gd")` at the top if not using the `class_name`. Do the same after the instantiate in `client/art/glb_character_kit.gd` (~line 26), and in `client/art/menu_art.gd` only where a 3D GLB is shown.

- [ ] **Step 4: Run test to verify it passes**

Run: `godot --headless --path . -- --test 2>&1 | grep -iE "glb_kit_filter|TESTS:"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add client/art/glb_weapon_kit.gd client/art/glb_character_kit.gd client/art/menu_art.gd tests/glb_kit_filter_test.gd
git commit -m "feat(art): apply NEAREST filter to GLB weapon/character/menu models

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

### Task 4: NEAREST real-GPU sanity + owner sign-off

- [ ] **Step 1:** Run the standalone A/B loop (above) on `master` vs branch; capture town screenshots showing buildings + a weapon viewmodel.
- [ ] **Step 2:** Send before/after to the owner. Confirm buildings/weapons read crisp-pixel (not blurry) and nothing regressed (e.g. no unexpectedly aliased UI).
- [ ] **Step 3:** On owner sign-off, proceed. (No extra commit — the code is already committed in Tasks 1–3.)

---

## Increment 1 — Authored Belfast sky + aligned sun + warm baseline (both renderers, low perf)

### Task 5: Wire the Belfast PureSky HDRI + align the sun

**Files:**
- Modify: `client/client.tscn` (Sky sub-resource, Environment ambient, DirectionalLight3D)
- Add to git: `assets/environment/skies/belfast_sunset_puresky_4k.hdr`, `assets/environment/skies/CREDITS.md` (already downloaded)

- [ ] **Step 1:** Ensure the HDR imports as a Texture2D. Run `godot --headless --import .` and confirm `assets/environment/skies/belfast_sunset_puresky_4k.hdr.import` is generated with `importer="texture"` (Godot imports `.hdr` as a 2D texture by default). If it imported as something else, open the file in the editor Import dock and set importer = "Texture2D", reimport.

- [ ] **Step 2:** Edit `client/client.tscn`. Add an ext_resource for the HDR at the top and replace the active sky material. Current header is `[gd_scene load_steps=4 format=3]` — bump `load_steps` as resources are added. Change the sky sub-resource from `ProceduralSkyMaterial` to `PanoramaSkyMaterial`:

```gdscript
[ext_resource type="Texture2D" path="res://assets/environment/skies/belfast_sunset_puresky_4k.hdr" id="1_sky"]

[sub_resource type="PanoramaSkyMaterial" id="PanoramaSkyMaterial_1"]
panorama = ExtResource("1_sky")
energy_multiplier = 1.0

[sub_resource type="Sky" id="Sky_1"]
sky_material = SubResource("PanoramaSkyMaterial_1")
```
Keep the existing `ProceduralSkyMaterial_1` sub-resource block in the file (unreferenced) as a cheap documented fallback, or delete it — either is fine; note the choice in the commit.

- [ ] **Step 3:** In the `Environment_1` sub-resource, keep `background_mode = 2` (sky) and set sky-driven ambient so the HDRI lights the scene:
```gdscript
ambient_light_source = 3        ; already set (Sky)
ambient_light_sky_contribution = 1.0
ambient_light_energy = 1.0      ; retune on GPU
```

- [ ] **Step 4:** Align the `DirectionalLight3D` to the HDRI's baked sun (low golden-hour angle, warm colour, long soft shadows). Start from:
```gdscript
light_color = Color(1, 0.85, 0.65, 1)   ; warm golden
light_energy = 1.2
shadow_enabled = true
shadow_bias = 0.04
directional_shadow_max_distance = 200.0
shadow_blur = 1.5                        ; softer edge for the low sun
```
and set its `transform` rotation so the sun points *from* the HDRI's bright spot (≈15–20° elevation). **This must be matched visually on the real GPU** — the Poly Haven API gives capture lat/long, not sun az/alt.

- [ ] **Step 5:** Run the suite — env is pure data, must stay green:
Run: `godot --headless --path . -- --test 2>&1 | tail -3`
Expected: `TESTS: <n> run, 0 failed`.

- [ ] **Step 6:** Real-GPU A/B (live client, low-sun HQ vantage). Iterate `ambient_light_energy`, `energy_multiplier`, and the sun transform until shadows agree with the sky and the grade reads golden-hour. **Owner signs off the A/B.**

- [ ] **Step 7: Commit** (include the asset + credits)
```bash
git add client/client.tscn assets/environment/skies/belfast_sunset_puresky_4k.hdr assets/environment/skies/CREDITS.md
git commit -m "feat(client): authored Belfast golden-hour PureSky + aligned warm sun

Client-only presentation. HDRI CC0 (Poly Haven), provenance in CREDITS.md.
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Increment 2 — Glow / bloom (both renderers, low perf)

### Task 6: Enable + tune HDR glow (hero sun bloom)

**Files:** Modify: `client/client.tscn` (`Environment_1`)

- [ ] **Step 1:** Add glow properties to the `Environment_1` sub-resource. Starting values:
```gdscript
glow_enabled = true
glow_normalized = true
glow_intensity = 0.8
glow_strength = 1.0
glow_bloom = 0.15
glow_blend_mode = 1        ; 0=Additive 1=Screen 2=Softlight 3=Replace — start Screen
glow_hdr_threshold = 1.0
glow_hdr_scale = 2.0
glow_levels/1 = 0.0
glow_levels/2 = 0.4
glow_levels/3 = 0.6
glow_levels/4 = 1.0
glow_levels/5 = 0.6
glow_levels/6 = 0.3
glow_levels/7 = 0.0
```

- [ ] **Step 2:** Suite green:
Run: `godot --headless --path . -- --test 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 3:** Real-GPU A/B at a vantage with the low sun in frame. Tune `glow_intensity`, `glow_bloom`, `glow_hdr_threshold`, `glow_blend_mode` toward Ref 1's warm radial sun bloom + edge glow — bright without washing mid-tones. Also spot-check the Compatibility path renders glow. **Owner signs off.**

- [ ] **Step 4: Commit**
```bash
git add client/client.tscn
git commit -m "feat(client): golden-hour HDR glow/bloom (hero sun bloom)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Increment 3 — Tonemap review (AgX vs Filmic) + exposure (both renderers, no perf)

### Task 7: A/B tonemap + lock exposure

**Files:** Modify: `client/client.tscn` (`Environment_1`)

- [ ] **Step 1:** With glow active, A/B the tonemapper. Current is `tonemap_mode = 2` (Filmic). Try AgX:
```gdscript
tonemap_mode = 4      ; 0=Linear 1=Reinhard 2=Filmic 3=ACES 4=AgX (verify enum in Godot 4.7 inspector)
tonemap_white = 1.1
tonemap_exposure = 1.0
```
Capture the *same* vantage under Filmic (2) and AgX (4) on the real GPU. AgX usually rolls the blown sun off with less orange-cream hue shift; pick whichever reads more BattleBit.

- [ ] **Step 2:** Lock `tonemap_mode` to the winner and tune `tonemap_exposure` for the golden-hour level (slightly bright, not blown).

- [ ] **Step 3:** Suite green:
Run: `godot --headless --path . -- --test 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 4:** Owner signs off the tonemap/exposure A/B.

- [ ] **Step 5: Commit**
```bash
git add client/client.tscn
git commit -m "feat(client): tonemap + exposure tuned for golden hour (AgX/Filmic A/B result)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Increment 4 — SSAO (Forward+ only, low–med perf)

### Task 8: Enable + tune SSAO grounding

**Files:** Modify: `client/client.tscn` (`Environment_1`)

- [ ] **Step 1:** Add SSAO to `Environment_1`. Conservative starting values (grounding, not grime):
```gdscript
ssao_enabled = true
ssao_radius = 1.0
ssao_intensity = 2.0
ssao_power = 1.5
ssao_detail = 0.5
ssao_horizon = 0.06
ssao_sharpness = 0.98
ssao_light_affect = 0.0
ssao_ao_channel_affect = 0.0
```

- [ ] **Step 2:** Suite green:
Run: `godot --headless --path . -- --test 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 3:** Real-GPU A/B at an **in-town** vantage (deploy onto a squadmate). Confirm contact shadows ground buildings/rocks/trees without a dark halo. Tune `ssao_radius`/`ssao_intensity`/`ssao_power`. **Owner signs off.**

- [ ] **Step 4: Compatibility check (once):** relaunch with `renderer_fallback=true` (or on laptop .116). Confirm the scene renders with SSAO simply absent and **no errors** in `/tmp/bf-client.log`. Note the result in the commit.

- [ ] **Step 5: Commit**
```bash
git add client/client.tscn
git commit -m "feat(client): SSAO contact-shadow grounding (Forward+; no-ops on Compatibility)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Increment 5 — Volumetric fog + god-rays (Forward+ only, med–high perf)

### Task 9: Enable + tune low-density volumetric fog

**Files:** Modify: `client/client.tscn` (`Environment_1`)

- [ ] **Step 1:** Add volumetric fog to `Environment_1`. **Low** density starting values:
```gdscript
volumetric_fog_enabled = true
volumetric_fog_density = 0.01
volumetric_fog_albedo = Color(1, 0.9, 0.8, 1)   ; warm
volumetric_fog_emission = Color(0, 0, 0, 1)
volumetric_fog_emission_energy = 0.0
volumetric_fog_gi_inject = 0.0
volumetric_fog_length = 96.0
volumetric_fog_detail_spread = 2.0
volumetric_fog_ambient_inject = 0.1
```
(The existing distance fog stays on — it carries depth on the Compatibility path where volumetric no-ops.)

- [ ] **Step 2:** Suite green:
Run: `godot --headless --path . -- --test 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 3:** Real-GPU A/B facing the low sun — tune `volumetric_fog_density`/`length`/`albedo` for subtle depth + god-ray shafts (Ref 1), NOT pea-soup. Keep density low.

- [ ] **Step 4: iGPU perf check:** run the live client on the laptop .116 (iGPU, Forward+). If the framerate tanks with volumetric fog on, add the single documented low-fx guard: in the client startup, when `renderer_fallback` is true OR a new `--low-fx` cvar is set, set `WorldEnvironment.environment.volumetric_fog_enabled = false` at runtime (client-only, no settings-UI required this pass). Keep it to one guard; do NOT build a tier system. Note whether the guard was needed.

- [ ] **Step 5:** Owner signs off the volumetric A/B.

- [ ] **Step 6: Commit**
```bash
git add client/client.tscn client/client_main.gd   # client_main only if the low-fx guard was added
git commit -m "feat(client): low-density volumetric fog + god-rays (Forward+; guarded on iGPU)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Finalization

### Task 10: Full suite, final owner review, land

- [ ] **Step 1:** Full suite green: `godot --headless --path . -- --test 2>&1 | tail -3` → `0 failed`.
- [ ] **Step 2:** Final real-GPU pass with ALL increments on: one golden-hour town flythrough A/B vs `master`. Owner sign-off on the whole look.
- [ ] **Step 3:** Update memory: refresh `blockfire-graphics-fidelity-direction` (lighting/post pass landed) and note the final env values + the .194 A/B recipe.
- [ ] **Step 4:** Land per AGENTS.md §11:
```bash
git fetch origin
git rebase origin/master        # or merge; reconcile if master moved
godot --headless --path . -- --test 2>&1 | tail -3   # re-verify green after reconcile
git checkout master && git merge --ff-only lighting-postfx-pass
git push origin master
```
Only push after the owner approves the final look.

---

## Self-review notes (author checklist — completed)

- **Spec coverage:** #0 NEAREST → Tasks 1–4; #1 authored sky+sun → Task 5; #2 glow → Task 6; #3 tonemap/exposure → Task 7; #4 SSAO → Task 8; #5 volumetric fog + iGPU guard → Task 9; validation loop → "Real-GPU A/B loop" section; fallback/Compatibility → Tasks 8/9 checks; landing → Task 10. All spec sections mapped.
- **Placeholders:** none — every code step shows code; test files show real assertions (flagged where signatures must be matched to real kit APIs).
- **Type consistency:** `ArtFilter.apply_nearest(root) -> int` defined in Task 1, called in Task 3; `--shot-after` / `--deploy` confirmed against `client/client_main.gd`; `TEXTURE_FILTER_NEAREST` used consistently.
- **Known adaptation points (by design, not placeholders):** exact test harness base class (GdUnit vs GUT), and the exact `building_kit`/`glb_weapon_kit` build-function signatures — each step tells the engineer to read the real file and match. Godot enum values (tonemap AgX, glow_blend_mode) tagged "verify in inspector".
