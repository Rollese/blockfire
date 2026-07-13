# ADR-0005: Client rendering backend (Vulkan Forward+, no GL Compatibility fallback)

- **Status:** Accepted (amended 2026-07-13 — see Update below)
- **Date:** 2026-06-16
- **Context milestone:** M7 (first rendered client)

## Context

M7 introduces the project's first *rendered* client (everything before it was headless: dedicated server + bot driver). Godot 4.6 offers three rendering methods, two of which are Vulkan-backed:

1. **Forward+** — Vulkan, clustered renderer, full feature set; the desktop default. Handles many dynamic objects and lights well.
2. **Mobile** — Vulkan, lighter-weight pipeline; can be faster on simple low-poly scenes but with fewer features.
3. **Compatibility** — OpenGL ES 3 / WebGL; widest hardware reach (old/integrated GPUs) but least performance and features. *Not* Vulkan.

The game is a low-poly, BattleBit-style 128-player FPS. For M7 it is run as a **LAN game for family and friends on mixed hardware** (the public/Steam release is deferred — see [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md)). Only the **client** renders; the server and bot driver remain headless and are unaffected by this decision.

## Decision

**Primary renderer: Forward+ (Vulkan). Configured fallback: GL Compatibility.**

- `rendering/renderer/rendering_method = "forward_plus"` for desktop.
- `rendering/renderer/rendering_method.mobile`-style fallback left at GL Compatibility so a machine without a working Vulkan driver (old/integrated GPU) can still launch the client.
- The choice is a project setting, validated by playtest, and reversible — switching to the Mobile (Vulkan) method is a one-line change if Forward+ ever strains the frame budget on the low-poly scene.

This decision concerns **only the client**. The dedicated server and bot driver export with the headless/dedicated preset (ADR-0002) and do no rendering.

## Rationale

- **Vulkan = maximum performance + modern compatibility.** Forward+ is Godot's blessed desktop default and comfortably handles the dynamic-entity counts a 128-player FPS produces.
- **GL Compatibility as fallback covers *ancient* hardware** — the "compatibility" half of the goal — without compromising the Vulkan path for everyone else. This matters for a LAN game on whatever machines friends/family bring.
- **Mobile (Vulkan) is held in reserve**, not chosen now: it can be faster on simple scenes but drops features we may want for feedback polish (P2). Re-evaluate only if Forward+ shows a frame-budget problem in playtest.

## Consequences

- The client export preset enables the Vulkan renderer; the headless server/bot presets are untouched.
- Renderer perf is a **playtest-validated** quantity (M7 is collaborative — AGENTS.md §10), not a headless gate number. The server tick budget (the headless gate) is independent of this choice.
- If public/Steam release is ever pursued, revisit for the broadest hardware matrix (Steam Deck runs both Vulkan and GL paths under Proton).

## Update (2026-07-13): client-side fallback toggle removed

A `renderer_fallback` checkbox/setting was added to the client settings menu at the same time as this ADR but was never wired to anything — Godot's rendering method must be set before the window/`RenderingServer` initializes, and no boot-time read of the setting was ever added. It sat as dead UI that did nothing regardless of what a player picked.

Removed rather than fixed: Vulkan 1.0 driver coverage is broad enough on any hardware from the last decade-plus (NVIDIA Kepler+, AMD GCN+, Intel Skylake-integrated+) that a real GL Compatibility fallback isn't worth the boot-time-relaunch plumbing it would need to actually work, for a LAN game played with family/friends. The risk that remains — a guest's laptop with a stale/never-updated GPU driver — is rare enough to handle case-by-case rather than build a permanent fallback path for.

`project.godot`'s `renderer/rendering_method.mobile = "gl_compatibility"` is untouched by this — that's a separate, functioning engine setting for mobile export templates (not currently a build target), not the removed desktop toggle.

If a real hardware-compatibility need shows up later (e.g. pursuing the public/Steam release noted above), revisit then with an actual boot-time implementation rather than resurrecting the dead toggle.
