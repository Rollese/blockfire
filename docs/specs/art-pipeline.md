# Spec — M7-P2 Art Pipeline (kit conventions, LOD, animation, combat VFX)

**Milestone:** [M7 — Art pass + UX polish](../milestones/M7-art-ux.md) (P2) · **Status:** drafted (brainstormed 2026-06-18) · **Branch:** `m7-p2-art-pipeline-spec` · **Reserved by:** `M7-art-ux.md` §Specs ("`art-pipeline.md` — **P2**, written when reached").

This spec is the **design-of-record for M7-P2 presentation**. Unlike the [procedural art-kit plan](../plans/2026-06-17-m7-p2-art-kit-procedural.md) (an implementation plan, now largely built + merged) and the [GLB-character increment](../plans/2026-06-18-m7-p2-glb-characters.md), this document does two things: it **records the established pipeline** as the contract going forward, and it **specs the still-open P2 art tracks** (LOD, animation beyond GLB v1, combat/feedback VFX) so each can get its own implementation plan.

Everything here is **client-only, presentation-only (AGENTS.md §7)**. No art code decides any gameplay outcome, sends intent, or lives in `shared/sim/` or `server/`. Where a visual depends on a gameplay value (damage bucket, suppression scalar, fire-mode, team), that value comes **from server-replicated state or an event the sim already emits** — never from a client-local decision. The client is view-only.

**Hard scope boundary (concurrent work):** **structure-destruction visuals — debris, collapse, rubble, fracturing — are OUT of scope and owned by M11 destructible buildings** (in-flight on branch `m11-destructible-buildings`, not yet merged to master). This spec touches structures only at the existing `StructureKit` damage-bucket tint that already shipped; any *new* destruction VFX is M11's. The one shared file this spec's animation track must eventually edit (`shared/net/protocol.gd`, to add `shooter_id` to `SHOT_FX`) is **also edited by M11** — that edit is therefore explicitly **sequenced after M11 merges** (§5). Everything else here is conflict-free with M11 right now.

---

## 1. Purpose & design decisions

Turn the proven-playable P1 client (placeholder primitives, full HUD) into something that reads as a coherent low-poly BattleBit-style game on the owner's playtest hardware — **without regressing the server tick budget** (rendering is client-only; the headless server/bots build no meshes) and **while staying performant on an integrated GPU** (the playtest box is the home laptop, RADV Renoir / Vulkan, rendering up to 128 entities).

Ratified decisions (from the M7-P2 re-scope + the 2026-06-18 brainstorm; anything genuinely needing the owner is in §9):

1. **The established `client/art/` factory pattern is the contract.** One `class_name` factory per asset category (`CharacterKit`/`WeaponKit`/`VehicleKit`/`StructureKit`/`PropKit`), each a presentation-only builder returning a `Node3D`, with `ArtPalette` as the single source of truth for materials/tints. New art categories follow this shape. Geometry is deterministic → **headless tests assert mesh structure** (child parts, `.size`, `mesh.get_aabb()`, `material_override.albedo_color`); **visual quality is the owner's playtest** of the preview scenes (AGENTS.md §10).
2. **Imported meshes (GLB) sit behind the same node interface and a settings flag.** The Kenney CC0 character GLBs (`assets/characters/*.glb`) are height-normalized to `STAND_HEIGHT` inside an identity-scale wrapper `Node3D` (so stance-scaling composes), loaded by `GlbCharacterKit`, animated by `CharacterAnim` (pure state→clip map) + `CharacterDriver` (idempotent clip play), and gated behind the persisted `ClientSettings.use_model_characters` flag with the procedural `CharacterKit` as fallback. **This is the import-flow template** for any future imported asset: CC0/owner-supplied source, normalize to sim dims, wrap, drive behind a flag, keep a procedural fallback.
3. **The renderer integrates only through its existing seams.** `world_renderer._make_entity_mesh()` / `_pose_entity()` and the structure pool are the only call sites; art tracks change *what mesh is built and how it is posed*, never netcode or calling code. Sizing stays tied to sim dims (`Stance.body_height`, `data/vehicles.json`, `PieceCatalog`).
4. **LOD strategy = distance culling + draw-call batching, not authored LOD meshes.** Per-node `visibility_range` sheds small character parts (helmet → gun → arms) with distance and demotes far entities to a single billboard/box; `MultiMesh` batches repeated static props/structures into one draw call. This fits the procedural-composite + single-GLB kit (which has no decimated variants) and targets the integrated-GPU frame budget directly (§3).
5. **Combat/feedback VFX are lightweight, pooled, and split by event-source readiness.** Muzzle flash, tracer polish, hit-spark and impact puffs are **mesh/quad-based and pooled** (no heavy `GPUParticles` at 128p); they are **buildable now** because their event (`SHOT_FX`/hit) already exists. Suppression, flashbang, fire-mode indicator and armor visual diffs are **design-ready but gated** on the upstream sim events that don't exist yet (M5.5) — specced here so they are plan-ready the moment M5.5 lands (§4).
6. **VFX read gameplay values from replicated state, never decide them.** A suppression blur is driven by the M5.5 `Pawn.suppression` byte; a fire-mode HUD glyph by the replicated fire-mode; an armor visual diff by the replicated armor class. The VFX layer is a function `(event | replicated value, listener pose) → (which effect, gain/intensity, where)`. (Mirrors the [audio spec](audio.md) decision 6/7 — same discipline, same upstream values.)
7. **Animation beyond GLB v1 is layered: pose-only first (no wire change), event-driven second (needs wire).** Authored crouch/prone poses and any stance/locomotion refinement need **no** new wire data and are conflict-free now. Remote **fire/reload/jump** animations need new client-side event sources: remote-fire needs `shooter_id` added to `SHOT_FX` (today it carries only `origin`+`dir`), and reload/jump need new signals. Those wire additions touch `shared/net/protocol.gd` — **shared with M11** — and are sequenced accordingly (§5).
8. **Nothing here changes the server, the bots, or the tick.** All edits land under `client/`, `assets/`, `tests/art_*` / `tests/*_vfx_*`, with the **single exception** of the gated `SHOT_FX.shooter_id` field (client/server-edge only, presentation payload, no rule logic) — and that one is held until M11 merges. The ≤48-bot headless smoke must stay green and the tick budget unaffected after every track.

---

## 2. Established pipeline (reference — already built & merged)

This section is descriptive: it is the current state every open track builds on. No work item here.

### 2.1 Directory & factory layout
```
client/art/
  art_palette.gd        # ArtPalette — single material/tint source (team tints, neutral, gun-metal,
                         #   structure materials, damage-bucket darken). Pure statics.
  character_kit.gd       # procedural blocky soldier (fallback when use_model_characters = false)
  glb_character_kit.gd   # imported GLB soldier, height-normalized, identity-scale wrapper
  character_anim.gd      # CharacterAnim — pure state -> clip-name map
  character_driver.gd    # CharacterDriver — idempotent AnimationPlayer clip play
  weapon_kit.gd          # per-Weapon blocky silhouette (AR/SMG/DMR/RPG), viewmodel + world model
  vehicle_kit.gd         # transport hull/wheels/turret, team-tinted, sized to vehicles.json
  structure_kit.gd       # sandbag/wall, per-damage-bucket tint  (damage TINT only — destruction = M11)
  prop_kit.gd            # cosmetic set-dressing (crate/barrel/barrier), no gameplay collision
  preview/               # standalone preview scenes for owner visual sign-off (no autoload/server)
assets/
  characters/*.glb       # Kenney "blocky characters" (CC0) + Textures/
  README.md              # records that the kit is code-generated + the GLB exception
```

### 2.2 Contracts that the open tracks must preserve
- **Forward convention:** entity local **+Z is forward** (gun/aim direction).
- **Height contract:** `CharacterKit.STAND_HEIGHT` == `Stance.body_height(STAND)`; the renderer scales the entity root vertically by `body_height / STAND_HEIGHT` per frame (crouch/prone squash). GLB kit normalizes to the same `STAND_HEIGHT`.
- **Team tint:** `ArtPalette.team_material(team)` → blue (t0) / red (t1) / neutral fallback. Friend/foe legibility is non-negotiable.
- **Damage bucket:** `StructureStore.bucket_of(health, max)` → 3/2/1/0; `StructureKit` darkens tint + adds a chip block at bucket ≤ 1. **This is the limit of structure visual change owned here** — M11 owns anything richer.
- **Renderer seam:** `_make_entity_mesh()` / `_pose_entity()` / structure pool. Keep the recycling free-list and all call sites.
- **Settings flag:** imported-vs-procedural is a persisted `ClientSettings` flag with a procedural fallback; tests inject `save_path` so the suite never clobbers the real `user://settings.cfg` (regression already in place).

---

## 3. Open track A — LOD & draw-call budget

**Goal:** keep the rendered client smooth at up to 128 entities on the integrated-GPU playtest box, by shedding detail and draw calls with distance — no authored LOD meshes.

**Mechanism (decision 4):**
- **Per-part visibility ranges.** Each kit exposes its parts in a detail order; the renderer sets `GeometryInstance3D.visibility_range_begin/_end` (+ margins) so non-silhouette parts disappear first: helmet/gun-detail/arms drop at mid-range, then the whole entity demotes to a **single team-tinted box or camera-facing billboard** at far range. The character still reads as "a soldier of team X facing direction D" at every level.
- **MultiMesh batching for repeated statics.** Identical props (crate/barrel/barrier) and same-piece/same-bucket structures render through one `MultiMeshInstance3D` per (kind, bucket) rather than N nodes — one draw call per batch. Re-batch only when a structure's bucket changes (the existing structure pool already keys on piece+bucket). *Coordination:* the structure-batch path reads from the same structure pool M11 evolves — this spec owns the **batching of the existing pieces**, M11 owns any new destruction geometry; the seam is the pool's per-id `(piece_id, bucket)` record.
- **No `GPUParticles` density at distance**; VFX (track B) self-cull on the same distance thresholds.

**Budget & measurement (the spec's real contract):**
- **Target:** a full 128-entity Conquest scene holds a **playable frame rate on the integrated-GPU playtest box** (owner-judged "smooth" — no authored fps gate, consistent with AGENTS.md §10 feel-is-playtested), with draw calls and primitives bounded by the batching above.
- **Method:** the implementation plan adds a **headless-measurable** proxy where possible (draw-call / primitive counts via the rendering info API in a windowed-but-offscreen harness, or a logged frame-time sample during the owner playtest) plus the **owner playtest** as the real gate. Pure LOD-selection logic (which detail level for a given distance) is a **pure function, unit-tested headlessly**; the visual result is the playtest.

**Out of scope for track A:** occlusion culling beyond Godot's built-in frustum/occluder (anti-cheat L3 LOS culling is a separate deferred track); impostor *baking*.

---

## 4. Open track B — Combat & feedback VFX

All VFX are **client-only, pooled, mesh/quad/shader-based**, self-culling on the track-A distance thresholds, and driven by events/replicated values (decision 5/6).

### 4.1 Buildable now (event source already exists)
| Effect | Source | Notes |
|---|---|---|
| Muzzle flash | local fire (`WeaponPredictor`) + remote `SHOT_FX` | Brief pooled quad/mesh at the muzzle; scaled by weapon; 1–2 frame life. |
| Tracer polish | `SHOT_FX` (remote) + local cosmetic beam | Upgrade the C1 cosmetic beam to a fading, weapon-tinted tracer; non-authoritative (hits stay server-confirmed). |
| Hit-spark / impact puff | hit terminus / `HITMARKER` | Per-surface-material spark (concrete/metal/flesh/dirt) where data is available; pooled. |
| Death/hit feedback polish | existing damage-arc/vignette HUD | Richer directional hit indicator + brief hit flash; HUD-model-driven, already partly present. |

### 4.2 Design-ready but gated (needs an upstream event that does not exist yet)
| Effect | Blocked on | Driven by | Notes |
|---|---|---|---|
| Suppression blur/shake | M5.5 suppression sim | replicated `Pawn.suppression` byte | Listener-global screen blur + slight shake; intensity = scalar. Pairs with the audio muffle ([audio.md](audio.md) §1.7). |
| Flashbang white-out | M5.5 flashbang | flash event/state | Fullscreen white fade + recovery curve; pairs with audio deafen. |
| Fire-mode HUD indicator | M5.5 fire-mode | replicated fire-mode | Small glyph (auto/burst/semi); pure HUD-model addition. |
| Armor visual diff | M5.5 armor class | replicated armor class | Light silhouette/tint differentiation of armor tiers; must not break friend/foe tint. |
| Weapon-swap / melee / sledge anims | M5.5 melee + swap | new client signals | Bridges into track C (animation). |

These are specced (effect, driver value, where it renders) so that when M5.5 lands the event, the effect is a plan-ready client-only addition — **no M5.5 sim work is in this spec**.

---

## 5. Open track C — Animation beyond GLB v1

**Layer 1 — pose-only (no wire change, conflict-free now):**
- Authored crouch / prone poses (replace the v1 vertical-shrink crouch and face-down prone tip with proper clips/pose blends from the GLB's 27 built-in clips).
- Locomotion refinement (idle/walk/sprint blend off the existing per-frame speed estimate).
- Downed (DBNO) pose is already the playtest-validated face-up calm idle — keep.

**Layer 2 — event-driven (needs new client event sources → shared-file edits):**
- **Remote fire animation** requires identifying *which* remote pawn fired. `SHOT_FX` today encodes only `(origin, dir)` — add a **`shooter_id`** field so the renderer can play the fire clip on that entity's `CharacterDriver`.
- **Reload / jump** animations require new client-side signals (the predictor knows local reload/jump; remote needs a replicated or evented source).

> **⚠️ M11 coordination gate.** `shared/net/protocol.gd` is edited by **M11 destructible buildings** (`STRUCTURE_DELTA`). Adding `shooter_id` to `SHOT_FX` (and any reload/jump wire/signal touching protocol) is therefore **sequenced after M11 merges** — or coordinated with the M11 agent — to avoid a protocol-enum/codec conflict. Layer 1 (pose-only) needs none of this and proceeds independently. This is the single point where the art pipeline is not already isolated from M11.

Pure logic (state→clip mapping, pose selection) stays in `CharacterAnim`-style pure helpers, unit-tested; the look is the owner's playtest.

---

## 6. Out of scope / boundaries

- **Structure-destruction visuals — debris, collapse, fracturing, rubble — → M11 destructible buildings.** This spec owns only the existing `StructureKit` damage-bucket *tint* + chip.
- **M5.5 sim mechanics** (projectile ballistics, suppression, flashbang, fire-mode, armor, melee) — this spec specs only their *presentation*, gated on M5.5.
- **Audio** — owned by [audio.md](audio.md) (already merged); this spec's VFX pair with audio cues but do not implement sound.
- **Anti-cheat L3 LOS replication culling** and **Steam/store art** — deferred online/anti-cheat track.
- **DCC-authored meshes beyond the existing Kenney character GLBs** — weapons/vehicles/structures/props stay procedural unless a future increment supersedes (the GLB-character pattern is the template if so).
- **Full keybind-rebinding UI** — deferred to a later UX task.

---

## 7. Architecture summary

```
                 replicated state / events (view-only, AGENTS.md §7)
                                    │
        ┌───────────────────────────┼────────────────────────────┐
        ▼                           ▼                             ▼
   client/art/ kits           VFX (pooled)                 CharacterAnim/Driver
   (mesh factories)        muzzle/tracer/impact            (state -> clip, pure)
        │                  suppression/flash (gated)              │
        ▼                           ▼                             ▼
        └──────────────►  world_renderer seams  ◄──────────────────┘
              _make_entity_mesh() / _pose_entity() / structure pool
                                    │
                           LOD: visibility_range + MultiMesh batching
                                    │
                              integrated-GPU frame budget (§3)
```
Each track is independently planned and tested; all share the renderer seams and the `ArtPalette`/sim-dimension contracts of §2.

---

## 8. Test plan & gates

- **Per track, headless geometry/logic tests** (`tests/art_*`, `tests/*_vfx_*`): LOD-level selection (pure function of distance), batch keying, VFX pooling/lifetime logic, animation state→clip mapping. Assert geometry/structure/values, never rendered pixels (AGENTS.md §10).
- **Regression:** full unit suite green; **≤48-bot headless smoke** (`ci/m5_p1_test.sh`) PASS with the tick budget unaffected after every track (rendering is client-only).
- **No 128-bot fleet gate is required for this spec's tracks** — these are client-render changes, not sim changes; the server tick is untouched. (This is also why the work is safe to run while the M11 agent holds the game2 fleet.)
- **Owner playtest sign-off** per track on the home-laptop client → game2 server+bots, recorded on [M7-art-ux.md](../milestones/M7-art-ux.md): friend/foe legibility, weapon-in-hand, vehicle, damaged structures still read; VFX read at range; animation looks right in motion; the 128-entity scene stays smooth on the integrated GPU.

---

## 9. Open questions for the owner

1. **LOD demote-to-billboard distance** — how far before a soldier becomes a single box/billboard? (Affects feel vs. fps; default: tune at playtest, start conservative.)
2. **VFX richness vs. fps on the integrated GPU** — if muzzle flash + tracers + impact at 128p cost too much frame budget, which sheds first? (Default: impact puffs → muzzle → tracers, tracers last since they aid target ID.)
3. **Track ordering** — build LOD first (biggest fps win), buildable VFX second, animation Layer 1 third, with Layer 2 + gated VFX waiting on M11/M5.5; or a different order?
4. **Do the gated M5.5-presentation effects (suppression/flash/fire-mode/armor) belong in this spec at all,** or should they move wholesale into the M5.5 line when it's scheduled? (Current choice: keep them here as design-ready stubs so M5.5 only adds the sim event.)

---

## 10. Plan handoff

Each open track (A LOD, B buildable-VFX, C animation Layer 1) is independently plannable **now** via `superpowers:writing-plans` → `subagent-driven-development`, conflict-free with M11. Track C Layer 2 and the gated VFX (§4.2) are held until their upstream (M11 `protocol.gd` merge / M5.5 sim) lands. Recommended first plan: **track A (LOD)** — biggest playtest-fps win, zero shared-file edits, fully isolated from M11.
