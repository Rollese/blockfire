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

**Deferred (P2 / separate vehicle-netcode pass — not C3 blockers):** grenade explosion VFX, corpse
remains on death, and vehicle riding-jitter / exit / friendly-only enter (needs `in_vehicle` + vehicle
`team` on the wire + seated-prediction suppression). This closes the **M7-P1 build order (C1→C2→C3)**;
next is the P1 gate (full-match human playtest with complete HUD).

### P2 — Art kit + LOD
Swap placeholder primitives for the low-poly blocky kit (characters, weapons, vehicles, environment) behind the same node interfaces, LOD pipeline, and audio/visual feedback polish (richer hit markers, animated damage indicators, SFX). Pure presentation on top of a proven-playable P1.

Also lands the **M5.5 presentation/feel deferrals** (the VFX/audio pieces of Combat Depth II — [combat-depth-2](../specs/combat-depth-2.md)): projectile **tracers** + muzzle flash, **suppression** screen blur/shake/muffle, **flashbang** white-out + deafen, melee/sledge/weapon-swap animations, fire-mode HUD indicator, armor visual diffs. **Audio gets its own spec** (`docs/specs/audio.md` — reserved; brainstormed when P2 starts): distance-attenuated + occluded gunfire, footsteps, **bullet crack/whiz** (from M5.5 projectiles), suppressor signature, suppression muffle, explosion/vehicle, directional.

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
- `art-pipeline.md` — **P2**, written when reached.

## Deferred out of M7
- **Steam auth + VAC** (Layer 5) and **anti-cheat L3 — LOS replication culling** (Layer 3) → later online/anti-cheat track; see [anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md).
