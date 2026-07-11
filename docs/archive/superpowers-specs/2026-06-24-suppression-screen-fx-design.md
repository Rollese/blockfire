# Suppression screen effect — design (M7 presentation deferral)

**Date:** 2026-06-24 · **Branch:** `m7-suppression-screen-fx` · **Owner:** claude (autonomous)
**Closes:** the M5.5-P2 → M7 deferral "suppression screen blur/shake/muffle" (the visual half;
audio half already shipped) and the in-code TODO at `client/client_main.gd` (`_suppression` is
decoded and fed to audio, with the comment *"M7 renders screen FX"* — never built).

## Why
BattleBit's suppression is a core gunfight-feel cue: when bullets crack near you, the screen
tunnels in (vignette), desaturates, and softens (blur), pushing you to break contact. The sim
already computes per-pawn suppression (`shared/sim/suppress.gd`, M5.5-P2) and replicates the
owner's scalar in `SELF_STATE` (1 byte). The client already consumes it for **audio** muffle/duck.
The matching **screen FX** is the only missing piece. This is the owner's stated top priority
(gunplay feel) and is screenshot-validatable without a human playtest.

## Scope
- **In:** a client-only screen overlay driven by the existing replicated suppression scalar; a pure
  intensity-mapping helper; a QA force-flag for screenshot validation.
- **Out (YAGNI):** screen shake / aim-sway (motion sickness; fights client prediction; the sim
  already widens the server fire ray under suppression so gameplay effect exists), any audio change
  (already shipped), any `shared/`/server/bot change, any new wire bytes.

## Architecture (mirrors the M5.5-P3 flashbang white-out)

Three pieces, each independently understandable/testable:

1. **Pure logic — `HudModel.suppression_intensity(suppression: float) -> float`**
   Maps the replicated suppression scalar `[0,1]` to a visual strength `[0,1]`:
   - `0.0` below `SUPPRESS_THRESHOLD` (0.25) — matches the audio threshold so audio + visual onset
     align and idle/low suppression shows nothing.
   - `smoothstep(0.25, 1.0, s)` above it — eased ramp to full.
   Deterministic, no engine deps → unit-tested in `tests/hud_model_test.gd` (or new
   `tests/suppression_fx_test.gd`).

2. **Render — `HudView` suppression overlay**
   A full-screen `ColorRect` with a `ShaderMaterial` (canvas-item shader). The client renders the
   3D world into the **main viewport** with the HUD as a `CanvasLayer` over it (`client.tscn`), so a
   canvas shader declaring `hint_screen_texture` samples the rendered world via the engine's
   automatic back-buffer. The shader, weighted by a single `strength` uniform `[0,1]`:
   - **Vignette tunnel** — radial darkening from screen edges inward; center stays clear so the
     crosshair/aim is readable.
   - **Desaturation** — lerp the sampled color toward its luminance, scaled by `strength`.
   - **Edge blur** — a cheap 4-tap box blur of the screen texture, blended in toward the edges
     (kept light; iGPU-friendly).
   `HudView.set_suppression(intensity)` writes the uniform. The overlay is built **before**
   `_build_blind()` so the flashbang white-out still covers everything (white-out > suppression).
   `mouse_filter = IGNORE`. At `strength == 0` the shader early-outs to the untouched screen color
   (no cost beyond a full-screen passthrough; acceptable — same as the always-present blind overlay).

3. **Wiring — `client_main`**
   Per-frame (next to the existing `set_blind` call): compute
   `HudModel.suppression_intensity(_suppression)` and call `_hud_view.set_suppression(...)`.
   Force `0.0` when not alive / downed / awaiting deploy (same gating as the blind overlay).
   Add `--suppress-test` arg (mirrors `--flash-test`): forces a fixed strength (~0.8) so the effect
   can be screenshot-validated with `--deploy=0 --suppress-test --shot-after=N`. Both are committed
   dev/QA flags.

## Data flow
`server suppress.gd → SELF_STATE byte → client_main `_suppression` → HudModel.suppression_intensity
→ HudView.set_suppression(uniform) → shader over the rendered viewport`. Unchanged: audio path off
the same `_suppression`.

## Testing
- **Deterministic:** unit test the pure helper — `0` at/below 0.25, monotonic increasing, `1.0` at
  `s=1.0`, clamped. Full suite must stay green (currently 713/0 on master; this branch adds tests).
- **Visual (AGENTS.md §10):** screenshot on .128 (iGPU, RADV Renoir) via the established recipe —
  rsync repo → `--import` → headless server+bots (loopback) → GUI client
  `--deploy=0 --suppress-test --shot-after=N`, scp the PNG back, confirm the tunnel/desaturate/blur
  veil over the world while the crosshair stays readable.

## Risks
- **Screen-texture availability on the iGPU** — `hint_screen_texture` in a canvas shader is standard
  Godot 4.6 and works on RADV; the back-buffer copy is auto-inserted. Mitigation: if blur misbehaves
  on the iGPU, the vignette+desaturate alone still reads as suppression (blur is the optional layer).
- **Always-on full-screen passthrough cost** — negligible at client framerates; the shader early-
  outs at `strength==0`. No server/tick impact (client-only).
