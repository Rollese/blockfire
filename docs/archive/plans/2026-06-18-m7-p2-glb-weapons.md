# M7-P2 Art Pipeline — Imported GLB Weapons (record)

**Milestone:** [M7-art-ux.md](../../milestones/M7-art-ux.md) (P2). **Spec:** [art-pipeline.md](../../specs/art-pipeline.md) §2 (GLB import flow), §5. Built 2026-06-18 in an isolated worktree (per [worktree-isolation] discipline), implemented directly (small, contained client-art + asset increment) with TDD.

**Goal:** Replace the procedural `WeaponKit` rendering with imported low-poly GLB weapons (owner-supplied Quaternius "Ultimate Guns Pack", CC0), mirroring how the Kenney character GLB superseded the procedural `CharacterKit`.

## What landed
- **Assets:** `assets/weapons/{assault_rifle,submachine_gun,sniper_rifle}.glb` (+ `.import`) — the three pack GLBs mapped to the `Weapon` enum (AR/SMG/DMR). The other 22 pack files are intentionally not committed (YAGNI). CC0, credited in `assets/README.md`.
- **`client/art/glb_weapon_kit.gd`** (`GlbWeaponKit`): `build(weapon_id)` loads the mapped GLB, normalizes the longest axis to `TARGET_LENGTH` (0.6 m) and yaws the barrel from the pack's native +X to our +Z forward (`MODEL_YAW`), wrapped like `GlbCharacterKit`. **Falls back to the procedural `WeaponKit`** for RPG (no launcher in this pack) and any unknown id / load failure — so every weapon always renders.
- **Integration:** `GlbCharacterKit.attach_weapon()` now builds via `GlbWeaponKit` instead of `WeaponKit`, so GLB soldiers carry the real imported rifle (AR default). No `world_renderer`/`shared`/`client_main` change; composes with the merged entity LOD.

## Verification
- `tests/art_glb_weapon_kit_test.gd` (5 tests): mapped weapons load a GLB mesh; normalized to `TARGET_LENGTH`; SMG/DMR map; RPG → procedural (warhead); unknown → procedural fallback.
- Updated `tests/art_glb_character_kit_test.gd` held-weapon assertion (GLB wrapper has mesh descendants, not ≥2 direct children).
- Full suite **487/0**; scene smoke clean.

## Playtest follow-ups (knobs; owner-tuned)
- In-hand **placement** (`GlbCharacterKit.WEAPON_OFFSET/ROT/SCALE`) and the weapon **forward/muzzle** orientation (`GlbWeaponKit.MODEL_YAW` — add `PI` if a model points backward) need eyeball tuning in a live match.
- **Per-weapon viewmodel** (first person) is a separate increment; `build_viewmodel` would use `GlbWeaponKit`.
- Wiring the local player's actual weapon id (from `WeaponPredictor`) so soldiers/viewmodel show the right class instead of default AR needs a `client_main` pass.
