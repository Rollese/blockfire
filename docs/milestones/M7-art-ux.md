# M7 — Rendered Client, Art Pass + UX Polish

**Status:** **DONE ✅** — **gate PASS 2026-07-05** (owner end-to-end human playtest, `conquest_town`, laptop 1080p → game2 server + 24 bots; full Conquest match start→win with victory/defeat end screen; all close-out items confirmed — see `docs/archive/sessions/2026-07-05-m7-playtest-round6.md`). *(Pulled before M6 on 2026-06-16: first human-playable rendered client; M6 voice + M10 air both need it.)* **Deferred out of M7 to their own tracks:** reserve-ammo economy (→M17), killfeed-off-by-design, map design + bot pathfinding, destruction fidelity, scoreboard stats, and B4/tick-lead netcode (`docs/specs/netcode-tick-lead.md`).

**Objective:** turn the headless/bot-only game into the **first human-playable rendered client** — a real first-person client that predicts/renders from the shared deterministic sim — then re-skin with the low-poly blocky kit and finish player-facing UX.

## Re-scope (2026-06-16, owner-directed)
Two phases: **P1 playable client + HUD**, **P2 art kit + LOD**. **Steam auth + VAC and anti-cheat L3 (LOS replication culling) were deferred** out of M7 to a later online/anti-cheat track (LAN game for now; both remain in [anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md) Layers 3 & 5).

**HUD rules (owner):** no health bar, no minimap; show ammo, compass w/ objective markers, squad members, TAB scoreboard; damage feedback via vignette + directional arc. Plus crosshair, tickets/capture, server-confirmed hitmarker, DBNO UI, and the death-recap card (killer/weapon/distance/HP/damage — no killcam, no position reveal).

**Authority boundary (AGENTS.md §7):** no gameplay rule logic in `client/`. Client-visual increments stay client-only; the few that cross into `shared/`+`server/` are additive cosmetic broadcasts or the one real netcode change (ADS spread), noted below.

## P1 — Playable client + HUD ✅
Real input → camera → movement/look prediction + reconciliation, client ammo/fire/reload prediction, remote pawn/vehicle interpolation, world render from `MapDef`/structures with placeholder primitives, BattleBit HUD. Projectile-aware fire prediction from the M5.5 ballistics dependency (cosmetic local tracer, non-authoritative for hits).

Build order (each an owner playtest): **C1 core infantry loop** → **C2 vehicles** → **C3 combat-depth UI**.

- **C1 — core infantry loop** ✅ (2026-06-17): `DeploySpawn`, wire `DEPLOY_REQUEST`/`DAMAGE_EVENT`/`SELF_STATE` + `HELLO.auto_deploy`; client `WeaponPredictor`, `Prediction`, `WorldView`, `world_renderer`, `hud_model`/`hud_view`, deploy/settings menus, `client_main`. Plan `docs/archive/plans/2026-06-16-m7-p1-c1-infantry-client.md`; ADR-0005.
- **C3 — combat-depth UI** ✅ owner-validated 2026-06-17 (tip `dc3479c`): wire `ROSTER`, `SET_SQUAD`, `DEATH_INFO`, `SELF_STATE`+`throwables`/`being_revived`, `DEPLOY_REQUEST`→u16; scoreboard/squad roster/death-recap/respawn-cooldown HUD; squad-select overlay (U). Exposed + fixed many pre-existing sim bugs (pawn/vehicle map-bound clamps, seat-vacate-on-death, downed-immune-no-false-hitmarker, downer-credited kills/recap, humans-never-Engineer). Suite 400/0; ≤48 smoke PASS (peak 15.76 ms). Plan `docs/archive/plans/2026-06-17-m7-p1-c3-combat-depth-ui.md`.

**P1 gate:** full-match human playtest on placeholder art with complete HUD — **PASS 2026-07-05** (see status header).

## P2 — Art kit + LOD ✅
Placeholder primitives → low-poly blocky kit behind the same node interfaces, plus the M5.5 presentation/feel deferrals (tracers, muzzle flash, suppression FX, flashbang white-out, melee/swap anims, fire-mode HUD, armor visuals). All landed as small validated increments (each `--*-test` QA flag + `.128` visual validation); details in git history. Summary, newest-relevant first:

**Wire-touching increments** (additive; canonical ids in [`wire-protocol-registry.md`](../specs/wire-protocol-registry.md)):
- `IMPACT_FX` (Msg 34) — bullet wall/dirt/flesh impact puffs + impact audio (2026-06-25/27).
- `GRENADE_FX` (Msg 35) — remote thrown-grenade arcs (2026-06-27).
- `GADGET_LIST` (Msg 36) — deployed C4/mine/bag rendering, authoritative-list rebuild (2026-06-27).
- `SUPPORT_LIST` (Msg 37) — heal/ammo/repair/revive feedback beams (2026-06-28).
- `SHOT_FX` gained trailing `shooter_id` (u32) — remote fire-recoil body twitch + authored GLB shoot clip (2026-06-27).
- `SELF_STATE` gained `bandage_count`+`bleed_halted` — DBNO self-bandage feedback (2026-06-27).
- `EntityState.armor_class` byte (ENTER records only) — armor visual diffs (2026-06-24).
- **Server-authoritative ADS spread** (2026-06-27, the one real netcode change): `InputCommand.buttons` **u8→u16** + `BTN_AIM` (bit 9); `Combat.reconstruct_ray(aiming)` × `ADS_SPREAD_MULT` (0.35) before the prone-bipod override; server honours `BTN_AIM` only when not sprinting. Proven deterministically (`combat_test`); suite 839/0.

**Client-only presentation increments** (no wire change): grenade explosion VFX (`DETONATION` slot 13) + corpse-on-death (2026-06-24); viewmodel swing/swap/recoil/reload/locomotion anims + sprint FOV kick; lighting env (sky/sun/fog); F3 debug toggle; capture/base ground rings; two-tone procedural ground; dynamic spread crosshair; ADS zoom + DMR scope; vehicle destruction hulk/fireball + damaged-vehicle smoke; flashbang cue + vehicle engine loop audio; footstep FX (dust + spatial audio); bullet crack/whiz near-miss audio + melee whoosh; killfeed name resolution; capture-point banners; grenade danger indicator; downed-teammate revive marker; thrown-grenade local arc; smoke-grenade clouds; landing FX + airborne/climbing poses; shell-casing ejection.

**GLB characters** ✅ owner-validated 2026-06-18: Kenney "blocky characters" (CC0) + 27 built-in clips, behind `ClientSettings.use_model_characters` (default false → procedural fallback). Weapons/vehicles/structures/props stay procedural. `client/art/` factories (`CharacterAnim`/`GlbCharacterKit`/`CharacterDriver`). Fixed the settings-clobber-by-test-suite bug (inject `SettingsMenu.save_path`). Plan `docs/archive/plans/2026-06-18-m7-p2-glb-characters.md`.

**Fire-mode + armor / suppression screen FX** designs: `docs/archive/superpowers-specs/2026-06-24-firemode-armor-fx-design.md`, `2026-06-24-suppression-screen-fx-design.md`.

**P2 gate (= full M7 gate):** full Conquest match with real art + complete HUD → folded into the 2026-07-05 owner sign-off.

## Rendering backend
**Forward+ (Vulkan)** primary, **GL Compatibility** fallback — [ADR-0005](../adr/0005-client-renderer.md). Client-only; server/bot stay headless.

## Run topology (playtest)
Client on the owner's desktop (display + GPU), dedicated server + bots headless on game2, over LAN (`--connect=<game2-ip>`). Agent builds/runs the headless tests + server; owner is the renderer at each checkpoint.

## Specs
- [client-prediction.md](../specs/client-prediction.md) — P1 client architecture, prediction/reconciliation, netcode, test plan.
- [hud-ui.md](../specs/hud-ui.md) — P1 HUD model+view, menus, keybinds.
- [ADR-0005](../adr/0005-client-renderer.md) — renderer choice.
- [art-pipeline.md](../specs/art-pipeline.md) — P2 presentation design-of-record (kit conventions, GLB import, LOD/animation/VFX tracks).

## Deferred out of M7
- **Steam auth + VAC** (Layer 5) and **anti-cheat L3 — LOS replication culling** (Layer 3) → later online/anti-cheat track ([anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md)).
