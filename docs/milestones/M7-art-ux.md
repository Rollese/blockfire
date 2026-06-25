# M7 — Rendered Client, Art Pass + UX Polish

**Status:** **in-progress** (brainstormed + speced 2026-06-16; on branch `m7-rendered-client`) · **Blocked by:** M5 land gate (done ✅) · *(pulled before M6 on 2026-06-16: this is the first human-playable rendered client; M6 voice + M10 air both need it)*

**Objective:** Turn the headless/bot-only game into the **first human-playable rendered client** — a real first-person client that predicts/renders from the shared deterministic sim — then re-skin it with the low-poly blocky kit and finish player-facing UX.

## Re-scope (2026-06-16, owner-directed)

After brainstorming, M7 was re-scoped to two phases. **Steam auth + VAC and anti-cheat L3 (line-of-sight replication culling) were both deferred** out of M7 to a later **online / anti-cheat track**: the project may stay a LAN game for family/friends (or a base for something else), so Steam's $100 + integration + ops cost isn't justified until there's a published-quality game, and L3 anti-wallhack/ESP only matters for *untrusted public* play (LAN friends don't need it, and it adds occlusion cost to a tick budget already near the edge). Both still live in [anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md) (Layers 3 & 5) for when that track is scheduled.

## Phases

### P1 — Playable client + HUD (the "it's a game now" phase)
Render the existing headless stub into a real first-person client: real input → camera → fill in prediction/reconciliation for movement/look, add client-side **ammo/fire/reload prediction** (the tracked M2/M7 gap), interpolate remote pawns + vehicles, render the world from `MapDef`/structures with **placeholder primitives** (capsules/boxes), and build the BattleBit-style HUD. Vehicles ride along (the substrate is already prediction-ready).

> **⚡ Inbound from M5.5 (owner-directed 2026-06-17):** bullets become **stepped projectiles** (drop + travel), so client fire prediction must be **projectile-aware** from Checkpoint 2 onward — the client spawns a **cosmetic local tracer** at fire (shared `shared/sim` integrator) but stays **non-authoritative** for hits (server-confirmed `KILL`/hitmarker, unchanged). Building this on hit-scan now would force a prediction refactor later. See [combat-depth-2](../specs/combat-depth-2.md) §1 / "Cross-milestone dependency".

**HUD (owner's rules):** **no health bar, no minimap;** show **ammo, compass (with objective markers), squad members, TAB scoreboard**; damage feedback via **vignette + directional arc** only. Plus crosshair, killfeed, tickets/capture status, hitmarker (server-confirmed), interaction prompts, DBNO UI, and the **death-recap card** (killer name / weapon / distance / killer HP / damage-taken breakdown — no replay killcam, no position reveal; from the 2026-06-17 gap review, needs a small `DEATH_INFO` server→victim message). See [combat-depth-2](../specs/combat-depth-2.md) §4.

**Menus:** deploy (full spawn-select, drives a new `DEPLOY_REQUEST`), minimal squad join/switch, essentials settings (sensitivity/FOV/volume/invert + renderer fallback; full keybind-rebinding deferred to P2).

**New netcode (client/server edge only):** `DEPLOY_REQUEST` (client→server, server holds humans un-deployed until they ask), `DAMAGE_EVENT` (server→victim, presentation-only), `SET_SQUAD` (minimal), `EntityState.ammo` (self-only, for ammo reconciliation). No gameplay rule logic enters `client/` (AGENTS.md §7).

**Build order (each a reviewable playtest on the owner's desktop):**
1. Core infantry loop — deploy → move (stances/lean/sprint/jump) → ADS/shoot/reload → kill/die/respawn → capture, core HUD.
2. Vehicles — enter/drive/gun/exit, predicted + rendered.
3. Combat-depth UI — squad list + scoreboard, DBNO/revive prompts, gadget/grenade use, build/destroy feedback, deploy-on-squadmate.

**P1 gate:** end-to-end **human playtest of a full Conquest match** vs bots on **placeholder art**, complete HUD, reaching a winner — judged playable + BattleBit-feeling by the owner. Recorded as evidence (owner sign-off + server log).

#### Checkpoint 1 — Core infantry loop — status (2026-06-17)

**Implementation complete; headless-validated; awaiting owner playtest.** Plan:
[`docs/plans/2026-06-16-m7-p1-c1-infantry-client.md`](../plans/2026-06-16-m7-p1-c1-infantry-client.md)
(Tasks 1–26). Runbook: [`docs/runbooks/running-client.md`](../runbooks/running-client.md).

Landed on `m7-rendered-client`:
- **Shared/server edge** — `DeploySpawn` (pure spawn-ref enumerate/validate/resolve); new wire
  messages `DEPLOY_REQUEST` / `DAMAGE_EVENT` / `SELF_STATE` + `HELLO.auto_deploy`; server honors
  `auto_deploy` (human held un-deployed → deploy screen), handles `DEPLOY_REQUEST`, emits
  `DAMAGE_EVENT` (pure `DamageDir`), sends `SELF_STATE` for ammo reconcile.
- **Client** — `WeaponPredictor` (predicted mag/reload mirroring server fire-gating, reconciles to
  `SELF_STATE`); `Prediction` extended for full-command + pitch reconcile; `WorldView`
  (snapshots + interpolation, self/remote split); `world_renderer` (placeholder primitives +
  camera + viewmodel); `hud_model` (ammo, compass, tickets/capture, killfeed, damage arcs/vignette —
  no health, no minimap) + `hud_view`; `input_map`/`input_controller`/`stance_pose`/`settings`;
  `deploy_menu` + `settings_menu`; `client_main` composition root. Renderer config + input actions +
  `client.tscn` ([ADR-0005](../adr/0005-client-renderer.md)).

Headless evidence (all green): full unit suite **351 tests, 0 failed**; ≤48-bot smoke
(`ci/m5_p1_test.sh`) **PASS** (winner valid, peak tick well under budget — server edge messages
don't regress it); end-to-end headless server+client connect reaches WELCOME → deploy → snapshots
with no errors. Two-stage review on the server-integration + composition-root tasks (read-only
reviewers); review findings (deploy-menu repopulate on death; reload-remaining reconcile) fixed.

**Remaining for C1 done:** owner playtests the full loop desktop→game2 and signs off as playable;
record sign-off + session server log here. Feel issues (look/move sign, sensitivity, recoil, HUD
layout) are follow-ups, not blockers.

#### Checkpoint 3 — Combat-depth UI — DONE ✅ (owner-validated 2026-06-17)

Plan: [`docs/plans/2026-06-17-m7-p1-c3-combat-depth-ui.md`](../plans/2026-06-17-m7-p1-c3-combat-depth-ui.md).
Landed on `m7-rendered-client` (tip `dc3479c`) — the 22-task plan plus a long owner-playtest fix loop.

**What landed (client/server-edge + presentation, no gameplay rule logic in `client/`):**
- Wire: `ROSTER` (names + per-client K/D/score), `SET_SQUAD`, `DEATH_INFO` (recap), `SELF_STATE`
  extended with `throwables` + a `being_revived` bit; `DEPLOY_REQUEST` widened to u16.
- `DeploySpawn` squadmate/vehicle refs **keyed by stable entity id/slot** (not array position, which
  aliased across the client/server edge); pure `DeathRecap`.
- HUD: scoreboard, squad roster, interaction prompt, throwable selector, **death-recap card**
  (left side, word-wrapped), respawn-cooldown countdown, "being revived — hold on!" cue, ammo/selector
  hidden while downed. Standalone **squad-select overlay (U)**. world_renderer structures + vehicle
  placeholder boxes (smoothed). deploy menu squadmate/vehicle options.

**Playtest-surfaced sim fixes** (pre-existing bugs the visual client exposed for the first time —
exactly the §10 purpose): pawn **and** vehicle movement clamp to the map's `world_half` (were hardcoded
1000, so they left small maps); **seat vacated on death** (respawn-trap); downed players can't fire and
aren't damageable (no false hitmarkers); bleed-out/give-up **credit the downer** with the kill +
correct recap (was self → "Killed by <you>", 0 m, 0 HP); killer HP/range **snapshotted at down-time**;
damage ledger reset on revive; humans **never roll Engineer** (the RPG-primary loadout had no
click-fire gun); prone is a toggle; no self-revive (teammate-only).

**Evidence:** full unit suite **400 run / 0 failed**; ≤48-bot smoke (`ci/m5_p1_test.sh`) **PASS**
(`winner=0 enters=4 veh_dead=1 rkt_veh=1`, peak **15.76 ms** < 33.3); Tasks 13 & 15 (authoritative
damage/deploy) two-stage read-only reviewed → SPEC-COMPLIANT + APPROVE. Owner ran the full loop
desktop→game2 and signed off.

**Deferred (P2 / separate vehicle-netcode pass — not C3 blockers):** ~~grenade explosion VFX~~ *(done 2026-06-24)*, ~~corpse
remains on death~~ *(done 2026-06-24)*, and vehicle riding-jitter / exit / friendly-only enter (needs `in_vehicle` + vehicle
`team` on the wire + seated-prediction suppression). This closes the **M7-P1 build order (C1→C2→C3)**;
next is the P1 gate (full-match human playtest with complete HUD).

#### P2 increment — Grenade explosion VFX — visual-validated ✅ 2026-06-24

Thrown grenades had no detonation visual (only the RPG rocket had a client-side cosmetic arc). The reserved `DETONATION` wire message (slot 13, "M7 frag VFX") is now used: the server `_detonate` funnel broadcasts `DETONATION(pos, kind)` to all human clients (frag/impact → `DET_EXPLOSION`, flashbang → `DET_FLASH`; bots skipped), and the client spawns `WorldRenderer.spawn_explosion` — an emissive expanding fireball core + smoke puff + scattered debris (frag), or a bright white pop (flash). Server-event (not client-predicted) so it fires for **other** players' grenades too. `--boom-test` QA flag pumps explosions in front of the camera. Suite **731/0** (protocol round-trip + renderer pool/age tests); visual-validated on .128 (iGPU). Presentation-only — the server still owns the blast.

#### P2 increment — Corpse-on-death — visual-validated ✅ 2026-06-24

Dead pawns used to just vanish. The server keeps a dead pawn in snapshots (`alive=false`) for ~5s before respawn, so `world_renderer._sync_entity_pool` reliably sees the alive→false transition: when it releases an entity because it **died in view** (vs. left interest), it drops a corpse at the last pose (face-down, armor-tiered) before releasing — fires exactly once (the id leaves `_active` and dead ids are skipped on acquire). Corpses linger `CORPSE_TTL` (14s) then sink into the ground; pool capped at `CORPSE_MAX=40` (oldest recycled) to bound cost. Client-only, no wire change. Corpses always use the **procedural CharacterKit** (a static GLB has no AnimationPlayer driving a clip → renders collapsed) and skip LOD (the proxy/range cull hid them). `--corpse-test` QA flag lays a few in front of the camera. Suite **735/0** (spawn/age/cap/finite tests); visual-validated on .128.

### P2 — Art kit + LOD
Swap placeholder primitives for the low-poly blocky kit (characters, weapons, vehicles, environment) behind the same node interfaces, LOD pipeline, and audio/visual feedback polish (richer hit markers, animated damage indicators, SFX). Pure presentation on top of a proven-playable P1.

Also lands the **M5.5 presentation/feel deferrals** (the VFX/audio pieces of Combat Depth II — [combat-depth-2](../specs/combat-depth-2.md)): projectile **tracers** + muzzle flash *(done)*, **suppression** screen blur/desaturate/vignette + muffle *(screen FX done 2026-06-24; muffle done with audio)*, **flashbang** white-out + deafen *(white-out done 2026-06-24)*, melee/sledge/weapon-swap animations *(done 2026-06-24)*, fire-mode HUD indicator *(done 2026-06-24)*, armor visual diffs *(done 2026-06-24)*.

#### P2 increment — Viewmodel swing/swap animations + melee & quick-swap inputs — visual-validated ✅ 2026-06-24

The first-person viewmodel was static (no recoil/swing/swap), and `MELEE`/`SWAP_WEAPON` existed on the wire but the client sent neither — so humans couldn't melee or use their secondary. Now: `ViewmodelAnim` (pure, tested) maps phase→pos/rot offset for **SWING** (a forward-down melee jab) and **SWAP** (the gun rises into view from lowered); `world_renderer._pose_viewmodel` applies the active anim each frame on top of `VM_OFFSET`, and `set_viewmodel_weapon` auto-plays the swap anim on any weapon change (RPG/class/quick-swap). New inputs: **melee (C)** sends `MELEE` + plays the swing; **quick-swap (mouse wheel)** toggles the slot + sends `SWAP_WEAPON` (swap anim plays when `SELF_STATE` reports the new weapon). `--swing-test` QA flag freezes the viewmodel mid-slash. Suite **738/0** (3 ViewmodelAnim curve tests); visual-validated on .128 (rest vs mid-swing A/B). Client-only presentation; server still owns the hit. *Sledge note:* the Engineer sledgehammer uses the same `MELEE` path, so it shares the swing anim (a dedicated heavier sledge swing is a feel follow-up). *(Humans never roll Engineer — server `_handle_hello` — so the local viewmodel never wields a sledge anyway.)*

#### P2 increment — Viewmodel recoil kick on fire — visual-validated ✅ 2026-06-24

The viewmodel had SWING + SWAP but **no fire animation** — the gun was dead-static while shooting (the obvious missing FPS juice, universal to every player vs. the Engineer-only sledge). Adds a **RECOIL** kind to `ViewmodelAnim`: a sharp up/back impulse (muzzle rises via −pitch, gun pushed back toward the eye via +Z, a touch of roll) that snaps in at t=0 (full envelope, no ramp-up) and decays over `RECOIL_DUR` (0.11 s) via `pow(1−t, 1.6)`. On full-auto each shot restarts it from t=0, so it reads as a sustained jolt. `world_renderer.play_viewmodel_recoil(now)` reuses the existing single anim slot + `_pose_viewmodel`; `client_main` calls it at the **same fire hook that spawns the local tracer** (`_wpred.step()` returns true → every predicted shot). `--recoil-test` QA flag freezes the viewmodel near the kick peak (mirrors `--swing-test`). Suite **743/0** (1 new RECOIL curve test); visual-validated on .128 (iGPU, Wayland): rest vs `--recoil-test` A/B clearly shows the muzzle-up/back kick. Client-only presentation (AGENTS.md §7) — server still owns the hit. Per-weapon recoil magnitude + multi-shot accumulation are feel follow-ups.

#### Increment — Lighting environment (sky/sun/fog) — visual-validated ✅ 2026-06-24

The client loaded `client.tscn` with a `WorldEnvironment` whose `ProceduralSkyMaterial` had **no properties set**, so it rendered Godot's washed-out grey **default** sky with a flat, untuned sun and zero atmosphere — the world read as a flat grey **void** even though the urban map (buildings, roads, capture/base markers) was rendering correctly. This is render-the-world P1 polish, not the P2 art kit (which is meshes/textures/LOD). Fix is **data-only** in `client/client.tscn` (+23 lines, no new nodes, no `shared/`/server/wire change, no gameplay/authority touched — AGENTS.md §7): tune `ProceduralSkyMaterial` (deep-azure top → hazy horizon, tighter sun disk), `DirectionalLight3D` (warm sunlight, energy 1.15, shadows to 160 m + bias 0.04), and `Environment` (Filmic tonemap, sky-driven ambient ~0.9, light distance fog density 0.0017 + aerial perspective so the flat terrain and distant buildings gain depth/scale). The camera shares the `World3D`, so the env applies regardless of which `Camera3D` renders. Suite **743/0** (no test touches the .tscn; confirms no load regression); **visual-validated on .128** (iGPU, RADV Renoir, Wayland) over the Town map — controlled HQ A/B (`--deploy=0`, fixed spawn) shows grey void → blue sky + warm sun + atmospheric haze, and in-town squadmate-deploy shots show buildings with lit/shadowed faces reading as a real scene. Sky-color/fog-density feel-tuning is an owner playtest follow-up.

#### Increment — F3 debug-overlay toggle — ✅ 2026-06-24

The green fps/draws/vram perf readout was always on screen with no way to hide it short of F8 free-fly photo mode (which also takes over the camera). Added an **F3 toggle** (`HudView.set_perf_visible` + `client_main._poll_debug_overlay_key`, edge-detected in `_process` like the F12/F9 screenshot + F8 photo polls) — **default ON** so the dev workflow is unchanged; flip it off for a clean HUD during play / screenshots. `_process` early-returns (skips the `Performance` reads) while hidden. Client-only (AGENTS.md §7). Tests `hud_view_perf_toggle_test.gd` (default-on / toggle / null-safe-before-build); suite **746/0**.

#### Increment — Capture/base zone rings (kill the screen-filling disc) — visual-validated ✅ 2026-06-24

Capture points and bases rendered as a big **solid-color filled cylinder disc** (`_make_cylinder_marker`, base = `b_radius*0.4` wide), so deploying at HQ filled the lower half of the screen with a flat blue blob and markers read as blobs, not zones. Replaced with a flat ground **ring** (`_make_ring_marker`, `TorusMesh` lies in XZ) at the **true** capture/base radius — BattleBit zone read — emissive + semi-transparent + unshaded so it glows at any range without dominating the view. Tall colored beacons (unchanged) stay the across-map nav landmark; the HUD capture bar stays the authoritative "in the zone" feedback. Client-only cosmetic (`world_renderer`), no wire/gameplay change. Tests `world_renderer_ring_marker_test.gd`; suite **749/0**; visual-validated on .128 (HQ A/B — blue blob gone; in-town — ring lies flat, beacon intact).

#### Increment — Procedural two-tone ground — visual-validated ✅ 2026-06-24

The ground was one flat muted-green `PlaneMesh` (an infinite uniform floor, no depth cue). Gave it an in-engine procedural noise albedo (`FastNoiseLite` simplex → `NoiseTexture2D`, seamless, two-tone green `color_ramp`, ~70 m tiling via `uv1_scale`) so open areas show low-frequency grassy patches — a subtle depth cue, not a loud pattern; roads/buildings sit on top so only open terrain shows it. No asset file, client-only cosmetic (`world_renderer`), no wire/gameplay change. Suite **749/0**; visual-validated on .128 (open-field shots show mottled terrain).

#### Increment — Dynamic spread crosshair — visual-validated ✅ 2026-06-24

The crosshair was a static `"+"` label. Replaced with a **4-tick reticle + centre dot** whose gap blooms with honest client-side spread — movement speed, airborne, and each shot widen it; crouch/prone tighten it; it returns to a small resting gap when still. Pure client feedback off the predicted pawn's `velocity`/`stance`/`grounded` + a per-shot `_ch_fire_bloom` that decays each frame (kicked at the same predicted-shot hook that fires the tracer/recoil). `HudView.update_crosshair(spread, hidden)` repositions the ticks each frame (and pulls the reticle while dead/downed/deploying). `--crosshair-test` QA flag forces a bloomed reticle. No wire/gameplay change (AGENTS.md §7). Tests `hud_view_crosshair_test.gd`; suite **753/0**; visual-validated on .128 (resting-tight vs `--crosshair-test`-wide A/B).

#### Increment — Viewmodel locomotion (walk bob + sprint-lower) — visual-validated ✅ 2026-06-24

The first-person weapon was dead-static while moving. Added a continuous locomotion offset composed on top of the base placement + any one-shot swing/swap/recoil: a **walk bob** (subtle step-cadence sway scaled by horizontal speed — zero at a standstill, <5 cm at full speed, Y-down-weighted so each step dips) and a **sprint-lower** (when sprinting = stand + grounded + speed>6.5, the gun dips and angles out of the aim, eased in/out). Pure math in `ViewmodelAnim` (`walk_bob` + `SPRINT_LOWER_*` consts); the renderer advances the bob phase by distance travelled and eases the sprint amount from the predicted pawn's `velocity`/`stance`/`grounded`. Client-only (AGENTS.md §7). `--sprint-test` QA flag freezes the lowered pose. Tests `art_viewmodel_locomotion_test.gd`; suite **757/0**; visual-validated on .128 (sprint-lowered vs in-aim A/B). Per-weapon bob tuning is a feel follow-up. **+ Sprint FOV kick:** the same eased `_vm_sprint_t` widens the camera FOV by up to +8° while sprinting (`_apply_camera`) for a sense of speed — cohesive with the sprint-lower, settles back when not sprinting; visible under `--sprint-test`.

#### Increment — Reload viewmodel animation — visual-validated ✅ 2026-06-24

The viewmodel had swing/swap/recoil but **no reload gesture** — reloading (one of the most frequent actions) left the gun dead-static. Added a `RELOAD` kind to `ViewmodelAnim`: the gun cants inward + dips to work the magazine (a trapezoid envelope so it reads over the whole, *variable* reload duration) with a couple of downward taps, then returns to rest. Triggered from the existing reload-start transition in `client_main` (alongside the reload sfx), stretched over the real per-weapon `reload_secs` via `play_viewmodel_reload(now, dur)` (reuses the one-shot anim slot + `_pose_viewmodel`). Client-only (AGENTS.md §7). `--reload-test` QA flag freezes it mid-reload. Tests `art_viewmodel_reload_test.gd`; suite **760/0**; visual-validated on .128 (canted-to-magwell vs in-aim rest).

#### Increment — Bullet impact effects (server `IMPACT_FX`) — validated ✅ 2026-06-25

Bullets vanished where they hit the world — no feedback that a round chipped a wall or kicked dirt. Added a cosmetic impact effect at the two clean projectile-termination points, mirroring the `SHOT_FX` cosmetic-message pattern (the owner-approved additive-client boundary — this is the first M7 increment to cross into `shared/`+`server/`, all the rest are client-only). **Wire:** new `IMPACT_FX` message (Msg 34) + `IMPACT_WALL`/`IMPACT_DIRT` surface kinds + codec (pos ×10, kind byte). **Server:** `_broadcast_impact_fx` (humans-only, unreliable, **per-tick capped at 24** to bound fan-out at bot scale) emitted from `_step_projectiles` when a bullet stops on a non-penetrable structure (wall) or hits the ground (`y<=0`, segment lerped to the surface) — presentation-only, no gameplay/authority change. **Client:** `IMPACT_FX` → `WorldRenderer.spawn_impact` = a small kind-coloured dust puff + chips (reuses the puff/debris pools; `_spawn_puff` gained an optional colour). `--impact-test` QA flag. Tests `protocol_test` (round-trip) + `world_renderer_impact_test` (puff+chips, non-finite guard, age-out). Suite **764/0**. **Server no-regression:** `ci/m5.5_p1_test.sh` PASS — `proj=117 projhit=20` (impacts emitted live in-match), peak tick **15.68ms** < 33.3. Client effect visual-validated on .128. *Follow-up: flesh/pawn impacts + penetrable pass-through impacts (only wall-stop + ground done).*

#### P2 increment — Fire-mode indicator + armor visual diffs — visual-validated ✅ 2026-06-24

Two more M5.5 → M7 presentation deferrals. Design: [`docs/superpowers/specs/2026-06-24-firemode-armor-fx-design.md`](../superpowers/specs/2026-06-24-firemode-armor-fx-design.md). Branch `m7-firemode-armor-fx`.

- **Fire-mode (client-only):** fire modes existed in the sim + wire (`SET_FIRE_MODE`) but nothing client-side selected or showed them — so the server always used the default (modes were inert end-to-end). Now `WeaponPredictor` tracks `fire_mode` (resets to the weapon default on swap), `cycle_fire_mode()`, and `step()` respects the mode (SEMI=one/press, BURST=burst_count/press, AUTO=continuous) so the local tracer matches authority. New `fire_select` input (**V**) cycles + sends `SET_FIRE_MODE`. HUD shows an `AUTO/SEMI/BURST` glyph above the ammo (hidden for RPG).
- **Armor diffs (1 immutable replicated byte):** armor tier is class-derived + immutable per life but wasn't replicated. Added `EntityState.armor_class` + `Pawn.to_state()`; `Snapshot` carries it as a **byte on ENTER records only** (no field-mask growth, zero per-tick cost; retained across CHANGED via the cached view entry). `ArmorVisual.apply()` tints the procedural soldier's torso vest (tan/olive/slate) + scales the helmet by tier — **not** team identity (friend/foe stays the blue triangle). `--armor-demo` QA flag pins LIGHT/MEDIUM/HEAVY dummies in front of the camera.
- **Validation:** full suite **726/0** (6 predictor + 2 snapshot-codec + 3 ArmorVisual tests). Visual-validated on .128 (iGPU): the three armor tiers render clearly distinct and the `AUTO` glyph shows in the HUD. GLB-character armor visual + exact shades/key are owner follow-ups (AGENTS.md §10).

#### P2 increment — Suppression screen FX — visual-validated ✅ 2026-06-24

Closes the visual half of the M5.5-P2 "suppression screen blur/shake/muffle" deferral (audio half already shipped). Design: [`docs/superpowers/specs/2026-06-24-suppression-screen-fx-design.md`](../superpowers/specs/2026-06-24-suppression-screen-fx-design.md). Branch `m7-suppression-screen-fx`.

- Driven by the **already-replicated** `SELF_STATE` own-suppression scalar (M5.5-P2) — the client already fed it to audio; this adds the matching screen effect. Client-only; no `shared/`/server/wire change.
- `HudModel.suppression_intensity()` (pure, unit-tested): zero below the 0.25 threshold (aligns with the audio onset), smoothstep to full. `HudView` full-screen canvas shader — first HUD child so it samples only the rendered world (HUD draws crisp over it) — applies a **tunnel vignette + desaturation + edge blur** scaled by a `strength` uniform; built before the flashbang white-out so a flash still covers it. `client_main` drives it each frame (alive + not-downed gating, same as the blind overlay).
- QA: `--suppress-test` mirrors `--flash-test`; with `--shot-after` it captures a same-camera **clean→suppressed A/B** for screenshot diffing.
- **Validation:** full suite **715/0**; **visual-validated on .128** (iGPU, RADV Renoir, Wayland) via the self-screenshot recipe — same-camera A/B confirms the tunnel-darken/desaturate/blur veil over the world while the HUD stays crisp, and a perfect passthrough at strength 0. Feel-tuning of intensity is an owner playtest follow-up (AGENTS.md §10). **Audio gets its own spec** (`docs/specs/audio.md` — reserved; brainstormed when P2 starts): distance-attenuated + occluded gunfire, footsteps, **bullet crack/whiz** (from M5.5 projectiles), suppressor signature, suppression muffle, explosion/vehicle, directional.

**P2 gate (the full M7 gate):** end-to-end human playtest of a full Conquest match **with the real art and complete HUD.**

#### P2 increment — Imported GLB characters (animated) — owner-validated ✅ 2026-06-18

First real art swap: the player **character** moves from procedural boxes to the **Kenney "blocky characters"** GLB (CC0), with their 27 built-in node-transform animations. Supersedes the *character* portion of the procedural-art plan (weapons/vehicles/structures/props stay procedural). Plan: [`docs/plans/2026-06-18-m7-p2-glb-characters.md`](../plans/2026-06-18-m7-p2-glb-characters.md). Branch `m7-p2-glb-characters`.

- **Architecture:** new `client/art/` presentation factories — `CharacterAnim` (pure state→clip map), `GlbCharacterKit` (load + height-normalize to STAND_HEIGHT, wrapped in an identity-scale `Node3D` so stance-scaling composes), `CharacterDriver` (idempotent clip play). Behind a persisted `ClientSettings.use_model_characters` flag (default **false** → procedural fallback intact). Renderer seam: `world_renderer._make_entity_mesh()` + `_pose_entity()`. No `shared/`/server/bot changes — client-only.
- **v1 animation:** idle / walk / sprint (from a per-frame speed estimate), crouch = vertical shrink, prone = face-down tip, **downed (DBNO) = face-up on the back + calm idle** (playtest-driven fix; the `die` clip read as "hands-up").
- **Validation:** full unit suite **465/0**, ≤48-bot smoke PASS (peak 19.45 ms), spec + code-quality two-stage review on the renderer integration. **Owner playtest 2026-06-18** on the home laptop (.128, RADV Renoir/Vulkan) → game2 server+bots: "looks much better… good enough for now"; crouch/downed/controls confirmed.
- **Follow-ups (tracked, not blocking):**
  - **Settings file clobbered by the test suite — FIXED 2026-06-18.** Real root cause was *not* the in-game menu (it preserves the flag): `SettingsMenu.apply()` saved via `ClientSettings.save_to()`'s default path, so `tests/settings_menu_test.gd` overwrote the real `user://settings.cfg` (all fields, incl. `use_model_characters→false`) on every `--test` run. Fixed by injecting `SettingsMenu.save_path` (tests use a temp file) + a regression test. *Separately observed, not yet addressed:* the menu may show default control values if `bind_settings` runs before `_ready`, which would reset sensitivity/FOV/volume on apply (distinct from the flag); and the flag still has no in-game toggle (file-only).
  - Part 2 refinements per the plan: authored crouch/prone poses; remote **fire** anim (needs `shooter_id` on `SHOT_FX`); reload/jump (need new signals); optional team/squad variants.

## Rendering backend
**Forward+ (Vulkan)** primary with **GL Compatibility** fallback for old hardware — [ADR-0005](../adr/0005-client-renderer.md). Client-only; server/bot stay headless.

## Run topology (playtest)
Client on the owner's **desktop** (display + GPU), dedicated server + bots **headless on game2**, connected over **LAN** (`--connect=<game2-ip>`) — the normal client/server split, sub-ms latency. The agent builds + runs the deterministic tests and the headless server on game2; the owner is the renderer at each checkpoint.

## Testing discipline (AGENTS.md §10)
Deterministic headless tests for everything testable — prediction/reconciliation, ammo prediction, vehicle prediction, HUD-model logic, the new netcode messages, interpolation/view logic. Human playtest for the rest — movement/gunplay feel, reconciliation smoothness, vehicle handling, HUD readability/layout, art. Don't tune feel blind.

## Specs
- [client-prediction.md](../specs/client-prediction.md) — P1 client architecture, prediction/reconciliation, new netcode, test plan. ✅
- [hud-ui.md](../specs/hud-ui.md) — P1 HUD model+view, menus, keybind defaults, test plan. ✅
- [ADR-0005](../adr/0005-client-renderer.md) — renderer choice. ✅
- [art-pipeline.md](../specs/art-pipeline.md) — **P2** presentation design-of-record (kit conventions + GLB import flow + open tracks: LOD, animation, combat VFX). Drafted 2026-06-18; structure-destruction visuals scoped out (owned by M11). ✅

## Deferred out of M7
- **Steam auth + VAC** (Layer 5) and **anti-cheat L3 — LOS replication culling** (Layer 3) → later online/anti-cheat track; see [anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md).
