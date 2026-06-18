# M6 — Voice (Proximity + Squad)

**Status:** todo · **Blocked by:** **M7 rendered client** (gate is human-validated in a live match → needs the client; reordered after M7 on 2026-06-16)

**Objective:** Positional proximity voice and squad voice channels.

## Scope
- Audio capture → encode (Opus) → stream subsystem.
- **Proximity** channel (positional, distance-attenuated) + **squad** channel.
- Routed so voice traffic respects interest/relevance (don't stream distant proximity audio).
- Runs alongside the 30 Hz sim without blowing the tick budget (separate path/threading as needed).

## Ratified design (brainstormed 2026-06-18 → `docs/specs/voice.md`)
- **Server relays, never mixes** — forwards opaque encoded Opus frames; never decodes (keeps voice off the tick).
- **Full tick isolation** — voice on a **second UDP port** + **dedicated relay `Thread` pinned to an E-core**; the sim tick publishes a **lock-free routing table** the relay reads. A 128p voice storm cannot inflate the P-core tick (the gate's isolation proof). See spec §2 for the single-threaded `_net.poll()`/ENet-channel rationale.
- **Opus via the project's first GDExtension** (`native/voice_opus/`, Rust `gdext`) → **[ADR-0006](../adr/0006-gdextension-voice-codec.md)** (escalation lever ADR-0001 reserved). Client-only linkage; server/bots don't load it.
- **Proximity = push-to-talk, enemies audible** (BattleBit signature), rendered positionally through the M7-P2 audio engine. **Squad = separate PTT, team-private**, flat 2D.
- Anti-spoof voice-session token issued on the game channel; client-side per-speaker mute; nearest-N decode cap.

## Gate
Voice works for human testers in a live match without breaking the tick budget. (Bots don't speak; this gate is human-validated.) **Isolation proof:** server `[perf]` shows the P-core tick budget held with heavy voice traffic.

## Specs required
- `docs/specs/voice.md` — **drafted ✅ 2026-06-18** (brainstorm-of-record). Next: implementation plan via `writing-plans`.
- `docs/adr/0006-gdextension-voice-codec.md` — **stub (Proposed) ✅**; promote to Accepted when the plan lands.
