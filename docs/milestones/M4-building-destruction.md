# M4 — Building & Destruction

**Status:** todo · **Blocked by:** M3 gate · *(M4–M6 may be reordered)*

**Objective:** BattleBit's signature fortification building and destructible environment, networked efficiently.

## Scope
- Place/remove fortification pieces (data-driven piece catalog).
- Networked structure state, replicated within the interest set (no global broadcast).
- Destructible terrain/objects — scoped to what the netcode budget allows.
- Server-authoritative placement validation (no client-trusted geometry).

## Gate
Building + destruction under **128-bot load** holds the tick and bandwidth budget set in M1.

## Risk note
Highest netcode/physics cost feature. Keep the destructible model coarse (chunk/voxel-ish state, not per-fragment) until profiling proves headroom. Define a graceful-degradation path if it threatens 30 Hz.

## Specs required
- `docs/specs/building.md`, `docs/specs/destruction.md`
