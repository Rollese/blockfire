# Lighting & Post-FX Pass — Design (golden hour)

**Date:** 2026-07-07
**Branch:** `lighting-postfx-pass`
**Owner-as-art-director; agent implements + real-GPU A/Bs each increment.**

## Goal

Add the atmosphere that makes BattleBit read as "pretty" despite blocky geometry, by
enabling and tuning Forward+ lighting/post-processing that is currently **off** in the client
Environment. Target mood: **golden hour** (owner reference Ref 1 — low centred sun with a warm
radial bloom, layered warm-lit clouds, backlit rim on foliage, long soft shadows, warm colour
grade, strong distance haze; Ref 2 = hazy-distance secondary read).

**This is client-only presentation (AGENTS.md §7).** No `shared/`, server, wire, or tick
changes. The full unit suite must stay green (`godot --headless --path . -- --test`, currently
**1379/0**), and the ≤48-bot smoke + fleet gate are render-agnostic and must be unaffected.

## Current state (verified)

`client/client.tscn` Environment is pure data: Filmic tonemap (mode 2, white 1.1), one warm
`DirectionalLight3D` (energy 1.35, shadows to 160 m, bias 0.04), a `ProceduralSkyMaterial`
(azure→hazy gradient, tight sun disk), and light distance fog (density 0.0006, aerial
perspective 0.12). **No glow, SSAO, SSIL/SSR, GI/SDFGI, or volumetric fog are configured**
(grep-confirmed). Renderer: `forward_plus` desktop / `gl_compatibility` fallback via
`client/settings.gd:11 renderer_fallback`. There is **no quality-tier system** —
`client/video_settings.gd` handles only resolution/window-mode.

## Key perf insight (reframes the "128p perf" worry)

Glow, SSAO, and volumetric fog are **screen-space, per-pixel** costs — they scale with
**resolution, not player count**. 128 players do not make them more expensive, and the headless
fleet gate does not run them at all. The real perf variable is **GPU tier** (the iGPU laptop),
not the fleet. Tune for the desktop RX 9070 XT; treat the iGPU as the graceful floor.

## Fallback plan (Compatibility renderer)

- **Glow** and **PanoramaSky** render on both Forward+ and Compatibility.
- **SSAO, volumetric fog, SSIL/SSR, SDFGI** are **Forward+ only** → Godot silently ignores them
  on Compatibility (graceful no-op, not broken). The `renderer_fallback` path keeps sky + warm
  sun + fog + glow — still a large upgrade, zero errors. **Must be verified on the laptop/compat.**
- **Explicitly skipping** GI/SDFGI/SSIL/SSR this pass (expensive, low ROI on blocky geometry).
- **No new quality-slider system** this pass (YAGNI — none exists). If the iGPU-on-Forward+
  chokes on volumetric fog, add *one* documented low-fx guard (e.g. keyed off `renderer_fallback`
  or a single cvar), not a full tier system. Logged as a follow-up.

## Architecture / where changes live

- **Environment effects** (sky, glow, SSAO, tonemap, fog, volumetric fog, sun): all as data in
  `client/client.tscn` sub-resources (`Environment_1`, the sky material, `DirectionalLight3D`).
  The camera shares the `World3D`, so the env applies regardless of which `Camera3D` renders.
- **Texture filter:** `client/art/*` kit scripts + GLB import presets (`.import` files /
  project import defaults). Client-only art.
- **Authored sky asset:** `assets/environment/skies/belfast_sunset_puresky_4k.hdr` (already
  downloaded, CC0, provenance in `assets/environment/skies/CREDITS.md`) wired as a
  `PanoramaSkyMaterial`.

## Increments (each = one commit, one real-GPU A/B the owner signs off)

### 0. Game-wide NEAREST texture filter — both renderers, no perf risk
`client/art/building_kit.gd:185` sets `mat.albedo_texture` but never `texture_filter` → blurry
buildings. Add `mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST`. Then roll out the
same across the other art kits that set albedo textures, and set the GLB import preset /
project texture-import default to Nearest so imported meshes match. The foliage kits already do
this — bring buildings/props/etc. in line so the pixel-cutout look is game-wide. **Do first** so
every later A/B uses the final texture look. Add/extend a unit test asserting kit materials use
`TEXTURE_FILTER_NEAREST` (mirrors the existing foliage-kit filter test).

### 1. Authored Belfast sky + aligned sun + warm baseline — both renderers, low perf
Wire `belfast_sunset_puresky_4k.hdr` as a `PanoramaSkyMaterial` on the Environment's `Sky`
(replaces `ProceduralSkyMaterial` as the active sky; keep the procedural resource around only if
we later want a cheap fallback). Set sky-driven ambient so the scene picks up the HDRI's warm
image-based light. **Align the `DirectionalLight3D`** (azimuth/elevation, warm colour, energy) to
the HDRI's baked sun so cast shadows agree with the sky's light direction — done visually on the
real GPU (Poly Haven API gives capture lat/long, not sun az/alt). Long, soft shadows for the low
sun. Establish a warm exposure baseline here since the sky sets the overall level.

### 2. Glow / bloom — both renderers, low perf
Enable Environment glow (the hero effect: warm radial sun bloom + rim on bright edges). HDR
glow with a threshold that catches the sun disk and bright sky/edges without washing mid-tones;
soft, fairly large bloom radius; bloom/blend tuned to Ref 1. Works on Compatibility too.

### 3. Tonemap review AgX vs Filmic + exposure — both renderers, no perf
A/B AgX vs Filmic against the golden-hour sun. AgX generally desaturates bright highlights more
gracefully (less orange-cream hue shift on the blown sun); Filmic is the current default. Pick
one on the real GPU and lock exposure/white. Tune with glow (#2) active since they interact on
the bright-sun rolloff.

### 4. SSAO — Forward+ only, low–med perf
Enable SSAO for contact-shadow grounding (under eaves, in corners, tree/rock/ground contact).
Conservative radius/intensity — grounding, not grime. No-ops on Compatibility.

### 5. Volumetric fog + god-rays — Forward+ only, med–high perf (iGPU)
Enable volumetric fog at **low density** for depth + light shafts (god-rays) from the low sun —
the atmospheric depth in both refs. Tune density low; watch iGPU cost (this is the priciest
increment; if it tanks the iGPU-on-Forward+, add the single low-fx guard noted above). No-ops on
Compatibility (the existing distance fog still carries depth there).

## Validation loop (set up first)

Live client on **.194** (owner choice): server+bots on game2 in tmux, rendered client onto the
desktop KDE-Wayland session over SSH (recipe: `blockfire-remote-client-launch`). rsync the
working tree to a **separate** dir on .194 (non-destructive), `godot --headless --import .` once,
then launch. Use a **fixed spawn** (`--deploy=0` HQ, or squadmate-deploy for a town vantage) +
`--shot-after` for repeatable before/after framings that don't fight the match lifecycle. For
golden-hour shots, pick a vantage with the **low sun in frame** (bloom/god-rays); use an in-town
vantage for SSAO/grounding. **Colour/exposure/AO cannot be trusted on llvmpipe / GL-compat /
xvfb — validate on the real GPU only (AGENTS.md §10).** Also spot-check the **Compatibility**
path (laptop or `--renderer-fallback`) once effects are in, to confirm graceful degradation.

## Testing

- Unit suite stays **1379/0** (env/art changes are data + material-filter; add a NEAREST-filter
  assertion test for the art kits).
- No new headless test can meaningfully assert visual quality — that is the owner's real-GPU
  sign-off per increment. The deterministic guarantee is "suite green + smoke unaffected."

## Out of scope / deferred

- GI/SDFGI, SSIL, SSR (expensive, skipped by decision).
- A full graphics quality-tier settings system (add only a single low-fx guard if forced).
- Modelled weapon scope (authored content, unrelated).
- Procedural-sky retune (superseded by the authored sky; procedural kept only as a possible
  cheap fallback).

## Landing (AGENTS.md §11)

Per increment: commit on `lighting-postfx-pass` → owner signs off the A/B → continue. When the
pass is complete and owner-approved: reconcile with origin, merge to master, push.
