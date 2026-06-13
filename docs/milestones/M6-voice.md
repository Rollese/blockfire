# M6 — Voice (Proximity + Squad)

**Status:** todo · **Blocked by:** M3 gate · *(M4–M6 may be reordered)*

**Objective:** Positional proximity voice and squad voice channels.

## Scope
- Audio capture → encode (Opus) → stream subsystem.
- **Proximity** channel (positional, distance-attenuated) + **squad** channel.
- Routed so voice traffic respects interest/relevance (don't stream distant proximity audio).
- Runs alongside the 30 Hz sim without blowing the tick budget (separate path/threading as needed).

## Gate
Voice works for human testers in a live match without breaking the tick budget. (Bots don't speak; this gate is human-validated.)

## Specs required
- `docs/specs/voice.md`
