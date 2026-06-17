# Spec — M7-P2 Audio (Spatial Combat Audio)

**Milestone:** [M7 — Art pass + UX polish](../milestones/M7-art-ux.md) (P2) · **Status:** drafted (brainstormed 2026-06-17, autonomous audio agent) · **Branch:** `m7-p2-audio` · **Reserved by:** `docs/specs/combat-depth-2.md` §"Explicitly deferred → M7-P2 (`docs/specs/audio.md`, reserved)".

This spec is the contract for the M7-P2 **audio system**: distance-attenuated, occluded, directional combat audio for the rendered client, with finite-voice management for 128-player matches. It is the audio counterpart to the [art-kit plan](../plans/2026-06-17-m7-p2-art-kit-procedural.md): everything new lives in a fresh `client/audio/*` namespace + `data/sounds.json` and is built to run **concurrently with the in-flight M7-C3 (combat-depth UI) work without touching any file C3 owns**. The single edit that touches C3-owned code — wiring the director into `client_main.gd` and adding the audio-bus config to `project.godot` — is a **deferred post-C3 integration task** (documented here and in the plan; **not executed** on this branch).

The audio engine is **presentation-only** (AGENTS.md §7). The client is **view-only**: audio is rendered from replicated state and one-shot events that the sim already emits/derives. **No audio code decides any gameplay outcome**, sends intent, or lives in `shared/sim/`. Audio never feeds back into authority (it is not lag-comp, not a hit signal). Where a cue depends on a gameplay value (suppression scalar, fire-mode, suppressor attachment), that value comes **from the server-replicated state**, not from a client-local decision.

---

## 1. Purpose & design decisions

Make a Blockfire gunfight *sound* like BattleBit: you locate enemies by ear — directional gunfire that attenuates with distance and muffles through walls, the supersonic *crack* of a bullet passing your head distinct from the distant *bang* of the muzzle, footsteps that betray a flanker, the dampened signature of a suppressed weapon, the muffled "underwater" wash of being suppressed, and explosions/engines that read at range. All of this is **cue rendering off authoritative events** — the audio layer is a function from `(event, listener pose, world occlusion) → (which sound, on which bus, at what gain/filter, in which 3D voice)`.

Ratified decisions (autonomous, from the captured M5.5/M7 requirements; anything genuinely needing the owner is in §10):

1. **Pure-logic core + thin Node, mirroring the project's established pattern.** All testable logic (attenuation, occlusion, suppression muffle, voice-stealing, bus routing, catalog lookup) is **pure static functions / pure classes** unit-tested headlessly — exactly how `Combat`, `Stance`, `Conquest` and `hud_model` are. The `AudioDirector` Node is a thin orchestrator that calls those helpers and drives Godot `AudioStreamPlayer3D`s; it carries **no logic that isn't in a tested helper**.
2. **Events are sourced from signals / method calls, never authority.** The director exposes a small request API (`play_event(...)`) and connects to client-side signals the renderer/netcode already raise (fire, hit, projectile-pass, footstep, explosion, engine, reload, melee, flash). It never reads input or decides outcomes.
3. **Finite voice budget with priority-based voice-stealing.** 128 players can generate far more simultaneous sounds than hardware voices. A fixed pool (`MAX_VOICES`, default 32) is allocated by **(priority, then proximity)**; a higher-priority/closer event steals the quietest/lowest-priority active voice. This is the headline scalability decision and the most-tested unit.
4. **Distance model = inverse-distance rolloff with a hard max-audible cutoff** (matches Godot `AudioStreamPlayer3D` `ATTENUATION_INVERSE_DISTANCE` semantics so the deferred wiring is a thin mapping). Each sound def carries `unit_size` (rolloff reference distance) and `max_distance` (beyond which gain = 0, the voice is never allocated — a key perf cull at 128p).
5. **Occlusion = volume cut + low-pass, driven by the M4 occlusion query.** When the segment listener→source is blocked by structures/terrain, apply an attenuation factor and lower the low-pass cutoff (a wall makes a shot *muffled and quieter*, not silent). The occlusion **boolean/coverage** comes from the same occlusion data the LOS-culling (M7 anti-cheat L3) and smoke-LOS use; the audio layer only maps coverage → (gain, cutoff). Partial occlusion supported via a `[0,1]` coverage scalar.
6. **Bullet crack/whiz is a listener-relative cue derived from M5.5 projectiles.** A supersonic round passing within `WHIZ_RADIUS` of the listener plays a *crack* whose timing/pan is the near-miss point, **separate** from the muzzle *bang* (which travels from the shooter at the speed of sound — modelled as a delayed, distance-attenuated event). This is the "you hear the snap before the bang at range" BattleBit cue.
7. **Suppressor + suppression are gain/filter modifiers on the existing path, not new sounds.** A suppressed weapon selects a quieter sound def + reduced `max_distance` (smaller "signature" radius). The **suppression scalar** (the M5.5 replicated `Pawn.suppression` byte) drives a **listener-global muffle** (master low-pass + slight duck) — the "incoming-fire deafening" feel — applied on the listener bus, not per-source.
8. **Directional audio is Godot's built-in HRTF/panning via `AudioStreamPlayer3D` 3D position.** The director places each voice at the source's world position relative to the listener (camera/pawn) transform; we do not hand-roll panning. The tested logic is *which* sound, *what gain/cutoff*, and *which voice* — not the spatialization, which the engine does.
9. **Sounds are data-driven via `data/sounds.json`** (same shape/discipline as `data/gadgets.json`, `data/vehicles.json`): one catalog of event → sound def. Audio *assets* (`.ogg`/`.wav`) are **owner-supplied / placeholder-tone-generated** and out of scope for this branch (parallel to the art kit being procedural) — the catalog references logical IDs and the deferred wiring resolves them to streams.
10. **The bus layout + `client_main` wiring is one deferred post-C3 task.** `project.godot` (audio buses + master volume) and `client_main.gd` (instantiate the director, connect signals, set the listener) are **C3/owner-owned files**; the plan documents the exact seam but **does not execute it** on this branch.

---

## 2. Sound-event taxonomy

Every audible thing is an **event** with a stable string `type`. The catalog (`data/sounds.json`) maps each `type` to a sound def. Events are grouped by **bus** (§3) and carry a **priority class** (§5).

| Event `type` | Source signal (client-side) | Bus | Priority | Notes |
|---|---|---|---|---|
| `gunfire` | fire event (weapon_id, fire_mode, suppressed) | `SFX` | high | Muzzle *bang*; suppressed variant = quieter def + smaller `max_distance`. |
| `bullet_crack` | M5.5 projectile passes within `WHIZ_RADIUS` of listener | `SFX` | high | Supersonic snap; listener-relative, distinct from `gunfire`. |
| `bullet_whiz` | projectile passes within `WHIZ_RADIUS` but subsonic / farther | `SFX` | med | Softer fly-by; lower priority than crack. |
| `impact` | projectile/hit terminus (surface material) | `SFX` | med | Per-material impact (concrete/metal/flesh/dirt) — material from the hit. |
| `footstep` | local + remote pawn locomotion (stance, speed, surface) | `SFX` | low | Rate from speed; volume from stance (prone/crouch quieter); culled early at distance. |
| `reload` | reload start/finish event | `SFX` | low | Local-loud, remote-quiet. |
| `melee` | knife/sledge swing + hit | `SFX` | med | Swing whoosh + impact. |
| `explosion` | grenade/RPG/C4/vehicle-death detonation | `SFX` | critical | Large `max_distance`; never stolen by lower classes. |
| `engine` | vehicle present + throttle (looping) | `SFX` | med | Looping voice tied to vehicle entity lifetime, not one-shot. |
| `flashbang` | flashbang detonation in LOS of listener | `UI`/`SFX` | critical | Deafen ring + duck (pairs with the M5.5 `blind_until_tick`). |
| `hitmarker` | server-confirmed `KILL`/hit feedback | `UI` | high | 2D, non-spatial (listener feedback, not world). |
| `ui_*` | menu/deploy/HUD interactions | `UI` | low | 2D. |

**One-shot vs looping:** most events are one-shot (allocate voice → play → release on finish). `engine` (and future ambience) are **looping voices** keyed by entity id; they update position/gain each frame and release when the entity leaves relevance. The voice pool (§5) treats a looping voice as a held allocation.

---

## 3. Audio-bus layout

A small, fixed bus graph. **The buses themselves are created in `project.godot` by the deferred wiring task** (§8); this spec defines the layout and every helper routes by **bus name string** so it is config-agnostic and testable without the buses existing.

```
Master
├── SFX        (all spatial world sound: gunfire, footsteps, explosions, engines, impacts)
│   └── (per-source low-pass is on the AudioStreamPlayer3D, not a bus effect)
├── UI         (2D, non-spatial: hitmarker, menus, flashbang ring)
└── Listener   (listener-global effects: the suppression muffle low-pass + duck)
```

- **`SFX`** carries every world/spatial sound. Per-source occlusion low-pass is applied on the individual `AudioStreamPlayer3D` (Godot supports a per-player attenuation filter), so occlusion does not need its own bus.
- **`UI`** is flat 2D feedback the listener always hears at the same level regardless of world position.
- **`Listener`** hosts the **suppression muffle**: a low-pass + small volume duck whose parameters are a pure function of the replicated suppression scalar (§4.3). It is global because suppression is "*you* are being shot at", a property of the listener, not of any one source.

Master volume + per-bus volumes are user settings (settings menu, owner/C3-owned). The catalog stores **relative** gains in dB so bus/master scaling composes cleanly.

---

## 4. Distance attenuation, occlusion & the suppression muffle

All three are **pure functions** in `client/audio/audio_mix.gd`, returning gain (linear `[0,1]`) and/or low-pass cutoff (Hz). No engine objects required → fully headless-testable.

### 4.1 Distance attenuation
Inverse-distance rolloff with a reference (`unit_size`) and a hard cutoff (`max_distance`):

```
gain(d) = 0.0                          if d >= max_distance   # culled, no voice
gain(d) = 1.0                          if d <= unit_size
gain(d) = unit_size / d                otherwise              # inverse-distance, matches Godot
```

- Monotonic non-increasing in `d`; `gain(unit_size) == 1.0`; `gain(>=max_distance) == 0.0`.
- The `>= max_distance ⇒ 0` rule is the **primary 128p perf cull**: out-of-range events never allocate a voice (§5). A suppressed weapon's smaller `max_distance` *is* its reduced signature.

### 4.2 Occlusion (gain cut + low-pass)
Given an occlusion **coverage** `c ∈ [0,1]` (0 = clear LOS, 1 = fully blocked) from the M4/M7 occlusion query:

```
occ_gain(c)   = lerp(1.0, OCCLUSION_MIN_GAIN, c)            # e.g. 1.0 → 0.35
occ_cutoff(c) = lerp(OPEN_CUTOFF_HZ, MUFFLED_CUTOFF_HZ, c)  # e.g. 20000 → 600
```

- Final source gain = `dist_gain * occ_gain`. Final source low-pass = `occ_cutoff` (combined with any per-def filter by taking the min).
- A wall makes a shot **quieter and darker**, never fully silent at `c=1` (you still hear the thump) — that is what `OCCLUSION_MIN_GAIN > 0` encodes.

### 4.3 Suppression muffle (listener-global)
Driven by the replicated suppression scalar `s ∈ [0,1]` (M5.5 `Pawn.suppression`):

```
supp_cutoff(s) = lerp(OPEN_CUTOFF_HZ, SUPPRESS_CUTOFF_HZ, smoothstep(s))  # whole world darkens
supp_duck(s)   = lerp(1.0, SUPPRESS_DUCK_GAIN, s)                          # slight global volume duck
```

Applied once on the `Listener` bus (§3), independent of any source. Below the M5.5 `SUPPRESS_THRESHOLD` it is a no-op (audio mirrors the gameplay threshold so the cue and the accuracy penalty agree).

### 4.4 Bullet crack vs. bang timing
At range the **crack** (supersonic round near the listener) and the **bang** (muzzle report) separate in time:

```
bang_delay_ticks(shooter, listener) = round( distance / SPEED_OF_SOUND * TICKS_PER_SEC )
```

The crack event fires when the projectile is nearest the listener (near-miss detection); the bang is scheduled `bang_delay_ticks` later. Both are distance-attenuated/occluded normally. The delay function is pure and unit-tested; the scheduling is the director's job. (v1 may collapse the delay to 0 for close range — `distance < CRACK_BANG_MIN_RANGE` — and only separate them past that, an owner-tunable threshold.)

---

## 5. Voice management — finite voices & priority stealing

The scalability core. Pure class `client/audio/voice_pool.gd` (no engine objects — it manages **slots** and returns decisions; the director binds slots to real `AudioStreamPlayer3D`s).

- **Budget:** `MAX_VOICES` slots (default 32; owner-tunable). Each active sound holds one slot.
- **Priority classes** (high number = more important): `LOW(0) < MED(1) < HIGH(2) < CRITICAL(3)`. From the taxonomy (§2).
- **Allocation request** carries `(priority, gain)` where `gain` is the already-computed distance·occlusion gain (so "closer/louder" is captured by `gain`, no second distance pass).
- **Rules (pure, deterministic):**
  1. If a free slot exists → allocate it.
  2. Else find the **weakest active voice**: lowest priority, ties broken by lowest gain.
  3. If the requesting event **outranks** the weakest (higher priority, or equal priority and higher gain) → **steal** that slot (return the evicted voice id so the director can stop it).
  4. Else → **drop** the request (return "no voice"); the event is simply not heard. Dropping the *weakest* keeps the loudest/most-important 32 sounds — exactly what a player needs to hear in a 128p firefight.
- **Inaudible events never reach the pool:** the director pre-culls anything with `dist_gain == 0` (≥ `max_distance`) before requesting a slot, so the pool only arbitrates audible sounds.
- **Looping voices** (engine) hold their slot until explicitly released (entity left relevance); they participate in stealing like any other (a `CRITICAL` explosion can steal an `engine` loop, which then re-acquires when a slot frees).
- **Determinism:** given the same ordered request stream + budget, allocation/eviction is fully deterministic and unit-tested (no RNG, no wall-clock).

---

## 6. Catalog — `data/sounds.json`

Data-driven, same discipline as `data/gadgets.json`. One object per event `type`:

```json
{
  "sounds": [
    {"type": "gunfire",      "bus": "SFX", "priority": 2, "gain_db": 0.0,  "unit_size": 8.0,  "max_distance": 400.0, "stream": "gunfire_ar"},
    {"type": "gunfire_supp", "bus": "SFX", "priority": 2, "gain_db": -9.0, "unit_size": 4.0,  "max_distance": 120.0, "stream": "gunfire_supp"},
    {"type": "bullet_crack", "bus": "SFX", "priority": 2, "gain_db": -2.0, "unit_size": 3.0,  "max_distance": 40.0,  "stream": "crack"},
    {"type": "footstep",     "bus": "SFX", "priority": 0, "gain_db": -6.0, "unit_size": 2.0,  "max_distance": 25.0,  "stream": "footstep_dirt"},
    {"type": "explosion",    "bus": "SFX", "priority": 3, "gain_db": 3.0,  "unit_size": 15.0, "max_distance": 600.0, "stream": "explosion"},
    {"type": "hitmarker",    "bus": "UI",  "priority": 2, "gain_db": 0.0,  "unit_size": 1.0,  "max_distance": 0.0,   "stream": "hitmarker"}
  ]
}
```

- `priority` is the §5 class int; `gain_db` is the relative def gain; `unit_size`/`max_distance` feed §4.1; `bus` is a §3 name string; `stream` is a logical asset id resolved by the deferred wiring (assets out of scope here).
- `max_distance == 0.0` marks a **non-spatial 2D** event (UI) — distance attenuation is skipped, it plays flat on its bus.
- `AudioCatalog` (`client/audio/audio_catalog.gd`, pure) loads + **validates** the file (every entry has the required keys, priority ∈ 0..3, `unit_size > 0`, `max_distance >= 0`, bus ∈ known set) and offers `def_for(type)` with a safe fallback. Validation failures are reported, not silently dropped (mirrors how the sim catalogs validate).

---

## 7. Components & data flow

```
client/audio/
  audio_catalog.gd   NEW  Pure. Load+validate data/sounds.json; def_for(type) → sound def; fallback.
  audio_mix.gd       NEW  Pure statics. distance_gain, occlusion_gain/_cutoff, suppression muffle,
                          bang_delay, combine() → final {gain, cutoff, bus}.
  voice_pool.gd      NEW  Pure class. Finite-slot allocation + priority/gain voice-stealing (deterministic).
  audio_director.gd  NEW  Thin Node. play_event(type, world_pos, ctx); holds the pool + a free-list of
                          AudioStreamPlayer3D; per-frame updates listener pose, loop voices, suppression bus.
                          ALL decisions delegate to the three pure helpers above. NOT autoloaded, NOT wired
                          into client_main on this branch.
data/
  sounds.json        NEW  Event→sound-def catalog.
```

**Flow (one fire event):**
1. Renderer/netcode raises a client signal (`fired(shooter_id, weapon_id, fire_mode, suppressed, world_pos)`) — these signals already exist or are trivially client-side; **no sim/authority change**.
2. `AudioDirector.play_event("gunfire" | "gunfire_supp", world_pos, {…})`.
3. Director: `def = AudioCatalog.def_for(type)`; `d = listener.distance_to(world_pos)`; `dist_gain = AudioMix.distance_gain(d, def)`. If `dist_gain == 0` → **return (culled)**.
4. `c = OcclusionQuery.coverage(listener_pos, world_pos)` (the M4/M7 occlusion data, read-only); `final = AudioMix.combine(dist_gain, c, def)` → `{gain, cutoff, bus}`.
5. `slot = VoicePool.request(def.priority, final.gain)`. If `"no voice"` → **return (dropped)**. If it returns an evicted id → director stops that player.
6. Director binds an `AudioStreamPlayer3D` to the slot, sets position = `world_pos`, `volume_db`, low-pass `cutoff`, `bus`, and plays. On `finished` → release the slot.
7. Each frame: director updates the listener transform, moves/updates loop voices, and sets the `Listener`-bus suppression muffle from the replicated scalar.

The director is **stateless about gameplay** — it is a renderer of cues. Steps 3–5 are the tested pure helpers; step 1's signals and steps 6–7's `AudioStreamPlayer3D` calls are the thin, owner-playtested shell.

---

## 8. Deferred integration seam (post-C3 — DO NOT EXECUTE on this branch)

The audio engine attaches to the client through exactly **two C3/owner-owned files**, deferred to a single post-C3 task (documented in the plan, never executed here):

1. **`project.godot`** — declare the audio buses (`Master → SFX, UI, Listener`) and default bus volumes / master volume setting. (Godot stores bus layout in `default_bus_layout.tres`; the wiring task creates that resource and references it.)
2. **`client_main.gd`** — (a) instantiate `AudioDirector` as a child node, (b) connect the existing client-side combat/render signals (fire, hit, projectile-pass, footstep, explosion, engine, reload, melee, flash) to `play_event`, (c) set the director's listener to the local camera/pawn each frame, (d) feed the replicated suppression scalar to the director.

Until then, the director is exercised **only** by unit tests and (optionally) a standalone preview harness — exactly the art kit's "Tasks 0–6 now, Task 7 post-C3" discipline. **This branch writes neither file.**

---

## 9. Test plan

All pure logic is headless-unit-tested (`tests/*_test.gd`, `extends TestCase`, every test asserts; run `godot --headless --path . -- --test --filter=audio`). Feel/mixing/timbre is the **owner's playtest** (AGENTS.md §10) and is not asserted headlessly.

- **`audio_mix` (`tests/audio_mix_test.gd`):** `distance_gain` is 1.0 at/under `unit_size`, 0.0 at/over `max_distance`, monotonic non-increasing between, and equals `unit_size/d` mid-range; `occlusion_gain` decreases with coverage and never hits 0 at `c=1` (`>= OCCLUSION_MIN_GAIN`); `occlusion_cutoff` drops with coverage; `suppression` muffle is a no-op below threshold and darkens/ducks above; `bang_delay` grows with distance and is 0 under `CRACK_BANG_MIN_RANGE`; `combine` multiplies dist·occ gain and takes the min cutoff.
- **`voice_pool` (`tests/voice_pool_test.gd`):** allocates into free slots; when full, a higher-priority request **steals** the lowest-priority voice (and returns the evicted id); equal priority steals only if **louder**; a weaker request when full is **dropped** (returns no-voice); the surviving set is always the top-`MAX_VOICES` by (priority, gain); release frees a slot; deterministic for a fixed request stream; a `CRITICAL` explosion can steal an `engine` loop.
- **`audio_catalog` (`tests/audio_catalog_test.gd`):** loads `data/sounds.json`; `def_for` returns the right def for known types and a safe fallback for unknown; validation rejects a malformed entry (bad priority / non-positive `unit_size` / unknown bus) and reports it; 2D entries (`max_distance == 0`) are flagged non-spatial.
- **`audio_director` (`tests/audio_director_test.gd`):** the **routing decision** is tested without an audio server by exercising the pure decision path the director uses (a testable `resolve(type, distance, coverage, supp)` that returns `{gain, cutoff, bus, priority}` or "culled") — out-of-range culls before the pool; suppressed type selects the smaller-signature def; dropped requests don't bind a player. (The actual `AudioStreamPlayer3D` mixing is owner-playtested, not asserted.)
- **Determinism:** the same ordered event stream + listener pose + occlusion + budget produces the same voice set every run.

The deferred §8 wiring is gated on C3 and **excluded from this branch's test run** (no buses/no `client_main` change to test here).

---

## 10. Open questions (owner)

Captured rather than blocking (autonomous agent). Defaults chosen so the engine ships; the owner can retune in playtest.

1. **Voice budget `MAX_VOICES`.** Defaulting to **32**. The right number depends on target hardware and how busy a 128p firefight gets; trivially tunable. Owner to confirm during the art/audio playtest.
2. **Occlusion query source.** This spec assumes the M4/M7 occlusion data (the same structure/terrain query that smoke-LOS and the M7 L3 LOS-culling use) exposes a client-readable `coverage(a, b) ∈ [0,1]`. If only a boolean LOS is available client-side at integration time, `coverage` collapses to `{0,1}` and the lerps still work (binary muffle). Owner/C3 to confirm the exact client-side occlusion accessor at wiring time.
3. **Crack/bang separation threshold.** `CRACK_BANG_MIN_RANGE` (below which crack+bang collapse to one report) is a feel value — defaulting to a placeholder; owner to tune by ear.
4. **Audio assets.** This branch ships the **catalog + engine only**; logical `stream` ids resolve to real `.ogg`/`.wav` (or generated placeholder tones) at wiring time. Source of assets (owner-supplied vs. procedurally-generated placeholders) is an owner call, parallel to the art kit being procedural.
5. **Suppressor as attachment vs. weapon variant.** Spec selects a `gunfire_supp` def when the shot is flagged suppressed (from the replicated attachment/loadout state). Whether "suppressed" is a per-shot flag or derived from the attachment set is an integration detail for the wiring task to map from existing replicated fields.

---

## 11. Explicit non-scope

- **No `client_main.gd` / `project.godot` edits on this branch** — the single integration seam (§8) is deferred post-C3.
- **No audio assets** (`.ogg`/`.wav`) authored here — catalog references logical ids; assets are owner-supplied/placeholder at wiring time.
- **No sim/authority/`shared/` change** — audio is view-only cue rendering; it reads replicated state, never writes it.
- **No hand-rolled spatialization** — Godot `AudioStreamPlayer3D` does panning/HRTF; we decide sound/gain/cutoff/voice only.
- **No music / dynamic-music system, no VOIP** — VOIP is M6; ambience beyond looping engine is a later pass.
- **No mixing/mastering "feel" sign-off here** — that is the owner's playtest (AGENTS.md §10).

## Specs

- This spec is the brainstorm-of-record for the M7-P2 audio system. Implementation plan: [`docs/plans/2026-06-17-m7-p2-audio.md`](../plans/2026-06-17-m7-p2-audio.md) (`writing-plans`), executed with `test-driven-development`. Reserved by `docs/specs/combat-depth-2.md`.
