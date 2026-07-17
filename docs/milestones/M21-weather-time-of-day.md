# M21 — Weather & Time-of-Day

- **Status:** planned (deferred — content/atmosphere pass, sequenced after the visual-authoring + map-content track)
- **Owner-directed:** 2026-07-16
- **Depends on:** the lighting/post-FX pass (done, `fb1db12`) and the map-authoring loop (so new maps can declare their own weather/time defaults).

## Objective

Per-map **atmospheric variation** so maps don't all read as the same golden-hour afternoon. Two orthogonal axes, both **cosmetic/presentation-first** (no sim/wire change unless a gameplay effect is later ratified):

### Weather (4 states)
- **Sunny** (clear sky, hard sun, crisp shadows) — the current look, as the baseline.
- **Partly overcast** (scattered cloud, softened sun, occasional shadow break-up).
- **Overcast** (full cloud, flat diffuse light, muted shadows, desaturated).
- **Raining** (overcast + rain particles + wet-surface sheen + rain ambience; heavier fog).

### Time-of-day (3 choices)
- **Morning** (low warm sun, long cool-blue shadows, light haze).
- **Noon** (high sun, short shadows, bright).
- **Afternoon** (the current golden-hour angle) — baseline.

**Night is explicitly out of scope for release** (owner-directed 2026-07-16) — a possible future update (would need NVG/flashlight/muzzle-visibility gameplay work, so it's its own track).

## Design notes / scope

- **Presentation layer only, first.** Weather + time set the `WorldEnvironment` / `DirectionalLight3D` / sky / fog / post-FX (all already parameterized by the lighting pass) plus a rain particle system and a wet-surface material flag. Server sim, ballistics, and the wire are untouched — a map's weather/time is a client render config broadcast once (or read from the map def).
- **Per-map declaration + optional match randomization.** Add `"weather"` and `"time_of_day"` fields to `MapDef` (map JSON), each either a fixed value or a list to pick from at match start (server picks deterministically and includes it in the join handshake so all clients agree — the only wire touch, a small enum, if randomization is wanted; a fixed per-map value needs no wire change since the client reads the map def).
- **Reuse the quality presets.** Rain particles + wet sheen must respect the existing High/Balanced/Performance/Potato presets (rain density scales, wet sheen off on Potato) so weather doesn't regress the iGPU perf floor (`blockfire-graphics-quality-perf`).
- **No gameplay effect in v1.** Rain does not change movement/traction/visibility as a *mechanic* (that would be a ratified departure needing its own note — BattleBit's weather is largely cosmetic). If reduced-visibility-in-rain is later wanted as a mechanic, spec it separately.

## Gate (must pass to close)

- Each of the 4 weather × 3 time combinations renders correctly on the real GPU (A/B screenshots per state, owner sign-off — this is a *look* gate, owner-eyeballed, like the lighting pass).
- Rain state holds the Performance-preset iGPU 60fps floor on the laptop (`tools/bench_render.gd`).
- If match-randomized weather/time is implemented: server picks deterministically, all clients agree (headless test on the handshake), no tick-budget regression at 128 bots.

## Deferred

- **Night** (post-release, own track — needs gameplay support).
- **Dynamic weather transitions mid-match** (v1 is fixed-per-match); a later polish item.
- **Weather-as-mechanic** (traction/visibility) — needs an ADR departure note if pursued.
