# ADR-0006: First GDExtension — Opus voice codec

- **Status:** Accepted (2026-06-18 — codec implemented + loads in Godot 4.6.3 headless; `native/voice_opus/`)
- **Date:** 2026-06-18
- **Context milestone:** M6 (Voice)
- **Relates to:** [ADR-0001](0001-core-runtime-language.md) (escalation lever), [spec/voice.md](../specs/voice.md)

## Context

ADR-0001 chose **GDScript-first** and reserved a GDExtension as the escalation lever, to be opened "only if needed" and "recorded in a follow-up ADR" that "must not fork gameplay rules out of `shared/`." M6 voice is the first concrete need: real-time **Opus** encode/decode at frame cadence (48 kHz mono, 20 ms frames). Pure GDScript cannot do this — Godot 4.6 ships no mic-side Opus encoder, and hand-rolling a codec in GDScript would miss the latency/quality bar. The owner ratified Opus-via-GDExtension during the M6 brainstorm (2026-06-18).

This is **not** the M1 hot-path escalation ADR-0001 anticipated (snapshot/interest/sim stayed in GDScript and passed the 128p gate). It is a **leaf capability** escalation: a codec the engine lacks, not a rewrite of a hot path.

Options considered:
1. **Rust GDExtension (`godot-rust/gdext`) wrapping `libopus`** — codec only, client-side.
2. Send raw/lightly-compressed PCM in pure GDScript (no native dep) — higher bandwidth, worse quality; rejected in the brainstorm.
3. Server-side mixing in a native lib — rejected (server must not decode; breaks the tick-isolation design).

## Decision

**Option 1: a Rust `godot-rust/gdext` GDExtension `native/voice_opus/`, scoped to the Opus codec only.**

- Exposes two leaf classes: `OpusVoiceEncoder.encode(PackedFloat32Array pcm) -> PackedByteArray` and `OpusVoiceDecoder.decode(PackedByteArray frame) -> PackedFloat32Array` (mono f32 samples — not stereo `Vector2`). Built with `godot-rust/gdext` 0.5.3 (feature `api-4-6`, verified against Godot 4.6.3) + the `opus` 0.3 crate (links system libopus via pkg-config). gdext requires a `base: Base<RefCounted>` field on each `#[class]`.
- **Client-only linkage.** The dedicated **server** and **bot driver** do **not** load the extension — the server relays opaque encoded bytes and never decodes (see [spec/voice.md §1–2](../specs/voice.md)); bots never speak. Only the rendered client builds/links it.
- **Leaf rule.** The extension contains **no gameplay rules and nothing from `shared/sim/`** — it is a pure codec behind a narrow interface, satisfying the ADR-0001 constraint.

## Consequences

- **Toolchain.** Building the **client** now requires Rust + cargo to compile `native/voice_opus/`. Server/bot builds and the M0–M5 gates are unaffected (they don't link it). A build runbook + prebuilt platform libs (Linux dev + the owner's desktop client target) ship with the M6 plan; CI builds the extension for the client artifact.
- **Reversibility.** Confined behind `OpusVoiceEncoder`/`OpusVoiceDecoder`; swappable (different codec/lib) without touching `client/voice/` callers.
- **Precedent.** Establishes the GDExtension pattern (manifest, per-platform libs, CI) for any future native need, but does **not** broaden it — each future extension needs its own ADR and stays a leaf.
- This stub is promoted to **Accepted** when the M6 implementation plan is written; open questions (exact gdext version, `libopus` vendoring vs system lib, platform build matrix) are resolved there and in spec/voice.md §10.Q5.
