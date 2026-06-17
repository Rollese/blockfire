# ADR-0005: Client rendering backend (Vulkan Forward+ with GL Compatibility fallback)

- **Status:** Accepted
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
