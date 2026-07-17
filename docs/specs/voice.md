# Spec — M6 Voice (Proximity + Squad VOIP)

**Milestone:** [M6 — Voice](../milestones/M6-voice.md) · **Status:** drafted (brainstormed 2026-06-18) · **Branch:** `m6-voice-spec` · **Gate:** human-validated in a live match (blocked on the M7 rendered client — voice needs human testers; bots don't speak).

This spec is the contract for the M6 **voice system**: real-time **positional proximity** voice (push-to-talk, enemies audible) and a **team-private squad** channel for the rendered client, isolated so voice traffic can never breach the 30 Hz authoritative tick at 128 players.

Unlike the M7-P2 [audio engine](audio.md) — which is **view-only cue rendering** off events the sim already emits — voice is the project's first **real-time bidirectional media stream**: capture → encode → network → decode → playback. It therefore carries new wire traffic and a new native dependency, but it remains **authority-neutral**: voice never decides a gameplay outcome, never feeds lag-comp or hit detection, and lives **entirely outside `shared/sim/`**. The server's only role is to **relay** encoded frames to the correct recipients; it **never decodes** voice.

The headline design decision (ratified during brainstorm, owner-approved 2026-06-18) is **full isolation of voice from the sim tick**: a **second UDP port**, a **dedicated relay thread pinned to an E-core**, and a **lock-free routing table** the tick publishes once per step. This is why a 128-player voice storm cannot inflate the P-core tick budget — the property the milestone gate must prove.

---

## 1. Ratified decisions

1. **Server relays, never mixes.** The server forwards each speaker's encoded Opus frames to the relevant receivers and **never decodes/mixes** them. Mixing would require decoding up to 128 streams server-side — a non-starter for the tick budget. Clients decode + render locally. Server CPU per voice frame is read-table + `memcpy` + `send()` × fan-out.
2. **Voice is fully isolated from the sim tick.** Voice does **not** ride the existing game connection. It uses a **second `ENetConnection` on a separate UDP port**, serviced by a **dedicated `Thread` pinned to an E-core** (logical CPUs 16–31; see [AGENTS.md §8](../AGENTS.md)). The single-threaded sim tick (`server_main._physics_process` on a P-core) never touches voice packets. Rationale in §2.
3. **Opus codec via a Rust GDExtension.** Encode/decode use Opus through a new `native/voice_opus/` GDExtension (`godot-rust/gdext`). This is the project's **first GDExtension** — the escalation lever ADR-0001 reserved — and is recorded in **[ADR-0006](../adr/0006-gdextension-voice-codec.md)**. 48 kHz mono, 20 ms frames (~24 kbps VBR while talking).
4. **Proximity = push-to-talk, enemies audible.** The proximity channel is keyed (PTT, not open-mic); everyone within `PROXIMITY_RANGE` hears it **regardless of team** — the BattleBit signature. Rendered positionally through the M7 audio engine (distance attenuation + occlusion).
5. **Squad = separate PTT channel, team-private.** A second PTT key transmits to the speaker's squadmates only; rendered flat 2D (non-positional). Squad voice is never relayed to enemies.
6. **Pure-logic core + thin shell, mirroring the house pattern.** All testable logic (packet codec, recipient selection, jitter buffering, PTT state, routing-table publish/read, mute filtering) is **pure static functions / pure classes** unit-tested headlessly — exactly how `Combat`, `Snapshot`, `voice_pool` (audio) are. The mic capture, Opus FFI calls, `AudioStreamGenerator` playback, and the `Thread`/socket shell are the **owner-playtested** edge.
7. **Authority-neutral.** No voice code reads input, writes sim state, or affects lag-comp/hit-reg. The relay reads a **published, read-only** routing snapshot; it cannot mutate the sim. `speaker_id` is server-assigned (never client-asserted) via the §4 token handshake, so voice can't spoof identity.
8. **Data-driven where it pays.** Tunables (`PROXIMITY_RANGE`, `MAX_VOICE_FANOUT`, `MAX_PROXIMITY_SPEAKERS`, jitter depth, frame ms) are named constants with BattleBit-aligned defaults, owner-retunable in playtest.

### Testing without live players (2026-07-16)

The milestone gate is "human-validated in a live match," but **almost all of voice is verifiable without a second human**, so the build is not blocked on multiplayer:

- **Pure logic core** — already 38 headless tests (codec, recipient selection, jitter, PTT, routing publish/read, anti-spoof re-stamp, mute).
- **Wiring (relay thread + capture/playback)** — testable with a **loopback two-virtual-client harness feeding synthetic PCM frames**: assert who-hears-whom, `PROXIMITY_RANGE` falloff, squad-channel team-privacy, server-assigned `speaker_id` (no client spoof), fan-out caps, and — critically — **no 30 Hz tick-budget inflation under a 128-speaker voice storm** (the headline isolation property). This is a normal fleet-gate load test, no ears required.
- **Real-ears feel** (latency, Opus quality, positional mix) is the only genuinely human part. It does **not** need a full lobby: a **2-machine smoke across the existing hosts** (desktop `.194` + laptop `.116`) exercises real mic→encode→relay→decode→playback between two people. Do this last, after the headless functional gate passes.

**Conclusion:** build + functionally fleet-gate voice headlessly now (unblocked); reserve only the 2-box mic/ears smoke for the end.

---

## 2. Why isolation (server-performance rationale)

The server is **single-threaded**: `server_main._physics_process()` runs `_net.poll()` then the full tick (move → lag → interest → fire → … → `snap`) on the **main thread pinned to a P-core**. `NetHost.poll()` (`shared/net/net_host.gd`) drains **every ENet event on every channel in one synchronous `while` loop at the top of each tick** (telemetered as the `poll` phase).

**ENet channels are a single UDP socket.** Channels (CONTROL/SNAPSHOT/INPUT) separate ordering/reliability, **not CPU/scheduling**. A voice channel on that same host would be drained in that same loop, on the P-core, *before the sim steps* — so a voice storm would directly inflate the `poll` phase. Headroom is thin: `snap` is already ~16 ms and the 128-bot tick rides 23–29 ms against the 33.3 ms budget, and voice load is **activity-driven and unbounded by game pacing** (a dense proximity brawl = speakers × ~50 frames/s × fan-out, landing exactly when the match is busiest).

A separate host on a separate port serviced by a separate thread removes voice packet processing from the P-core tick **by construction**: the voice socket, its drain loop, and the relay CPU all live on an E-core. The only sim↔voice contact is the **read-only routing table** (§3.3). This is the established Source-style design and aligns with the project's existing P/E-core pinning discipline.

---

## 3. Architecture

### 3.1 Module layout

```
native/voice_opus/         NEW  Rust GDExtension (godot-rust/gdext). Exposes:
                                  OpusVoiceEncoder.encode(PackedFloat32Array pcm) -> PackedByteArray
                                  OpusVoiceDecoder.decode(PackedByteArray frame) -> PackedFloat32Array
                                  (mono f32 samples — PackedFloat32Array, NOT Vector2/stereo)
                                Built via cargo (gdext 0.5.3, feature api-4-6; opus 0.3); .gdextension
                                manifest + platform libs (see ADR-0006 / §9).
shared/net/voice_packet.gd  NEW  pure. VOICE wire codec + validation (§4.1).
shared/net/voice_routing.gd NEW  pure. recipients_for(speaker, table, kind) -> Array[int] (§3.4).
server/voice_relay.gd       NEW  Thread. Owns the 2nd ENet host; token auth; per-frame recipient
                                 selection off the published table; fan-out send. NEVER decodes.
server/voice_routing_table.gd NEW pure. double-buffered {id -> RouteEntry}; publish()/read() (§3.3).
server/server_main.gd       (mod) per tick: build + publish the routing table; in WELCOME, mint a
                                 voice_token and advertise the voice port. (No voice on the tick path.)
client/voice/
  voice_capture.gd   NEW  AudioEffectCapture tap -> PCM frames -> OpusVoiceEncoder. PTT-gated.
  voice_jitter.gd    NEW  pure. per-speaker jitter buffer: ordered insert, late/dup drop, pop-in-order.
  voice_playback.gd  NEW  per-speaker decoder + jitter -> AudioStreamGenerator; proximity routed
                          through the M7 audio engine (audio_mix gain/occlusion + AudioStreamPlayer3D),
                          squad as flat 2D on the Voice bus.
  voice_ptt.gd       NEW  pure. PTT state machine (idle/proximity/squad; key-down/up, channel pick).
  voice_client.gd    NEW  Node. 2nd ENet connection + token handshake; owns capture + playback set;
                          client-side mute set; feeds the listener pose to playback.
data/                       (no new catalog; voice tunables are constants — see §8)
```

AI/sim stay untouched: nothing under `shared/sim/`, `server_main`'s tick phases, or the bot driver changes behaviour. `server_main` gains only the **publish** step (pure, ~128-entry copy) and the WELCOME token mint.

### 3.2 Ports & connections

- **Game host:** existing `NetHost` on the game port (default 7777).
- **Voice host:** a second `ENetConnection` on the **voice port** (default **7778**), one channel (unreliable). Owned and serviced **only** by the voice thread (ENet hosts are not thread-safe across threads; each host is touched by exactly one thread).
- Clients hold **two** connections: game (authoritative) + voice. The voice connection is associated to the game session by the §4 token.

### 3.3 The routing table (the one sim↔voice seam)

Each tick, after movement/squad updates, `server_main` builds a compact table and publishes it lock-free:

```
RouteEntry := { pos: Vector3, squad_id: int, team: int, voice_peer_id: int, alive: bool }
table      := { player_id: RouteEntry }     # ~128 entries
```

- **Double-buffered:** the tick writes buffer `1 - active` then flips a single `active` index under a trivial `Mutex` (the swap is one int store; no contention with the read). The voice thread `read()`s the currently-active buffer.
- **Staleness:** the voice thread sees a table ≤1 tick (≤33 ms) old — irrelevant for "who is in range / in my squad." Position is only used to pick recipients, never for authority.
- `voice_peer_id` maps a player to their **voice** ENet peer (filled by the token handshake, §4); `0`/absent ⇒ that player has no voice connection ⇒ never a recipient.

The routing table is the **primary** seam (tick → voice, read-only for the relay). The only other cross-thread state is a **small bounded thread-safe bind-handoff queue** in the reverse direction (voice → tick): when the relay authenticates a token (§4.2) it enqueues a `(player_id, voice_peer_id)` binding, which the tick drains and folds into the table just before the next publish. Both seams are bounded, single-purpose, and lock-free on the hot path (the table via buffer-flip, the bind queue drained once/tick); no other shared mutable state exists between the threads.

### 3.4 Recipient selection (`shared/net/voice_routing.gd`, pure)

Given the speaker's `RouteEntry`, the table, and the channel kind:

```
recipients_for(speaker_id, table, PROXIMITY) =
    [ id for id, e in table
      if id != speaker_id and e.alive and e.voice_peer_id != 0
      and dist(e.pos, speaker.pos) <= PROXIMITY_RANGE ]
    -> sorted by distance, truncated to MAX_VOICE_FANOUT

recipients_for(speaker_id, table, SQUAD) =
    [ id for id, e in table
      if id != speaker_id and e.team == speaker.team and e.squad_id == speaker.squad_id
      and e.voice_peer_id != 0 ]
```

Deterministic, no RNG, no engine calls → fully headless-testable. `MAX_VOICE_FANOUT` bounds proximity fan-out (a packed brawl never explodes); squad fan-out is naturally bounded by squad size (~4). Per-receiver decode is bounded separately by `MAX_PROXIMITY_SPEAKERS` (§5).

---

## 4. Wire protocol & session

### 4.1 VOICE packet (voice port, unreliable)

```
VOICE_FRAME := u16 speaker_id | u8 kind (0=proximity,1=squad) | u16 seq | bytes opus_frame
```

- Client → server: `speaker_id` is **ignored on ingress** (the relay derives the true id from the authenticated voice peer, §4.2) — included only so server → client carries the rendered speaker. The relay **overwrites** it with the trusted id before fan-out.
- `seq` drives the per-speaker jitter buffer (§5) and late/duplicate drop. Unreliable transport: lost frames are simply gaps (voice tolerates loss; never retransmit).
- `kind` selects positional (proximity) vs 2D (squad) rendering and the §3.4 recipient set.
- `voice_packet.gd` is the pure encode/decode + validation (length bounds, known `kind`, frame ≤ `MAX_OPUS_FRAME_BYTES`); malformed frames are dropped + counted, never crash the thread.

### 4.2 Session association (anti-spoof)

The voice connection must be tied to an authenticated game session so `speaker_id` is trustworthy:

1. On game-channel `WELCOME`, `server_main` mints a short-lived random **`voice_token`** for that player and includes it + the **voice port** in `WELCOME`.
2. The client opens the voice connection and sends `HELLO_VOICE { token }` (reliable, first voice packet).
3. `voice_relay` validates the token against the pending set, binds `voice_peer ↔ player_id`, writes `voice_peer_id` into that player's `RouteEntry` (via a small thread-safe handoff queue drained by the tick before publish), and discards the token.
4. Voice frames from an unbound/booted peer are dropped. On disconnect, the binding and `voice_peer_id` are cleared.

Tokens are single-use, expire (`VOICE_TOKEN_TTL`), and never reused — a peer cannot claim another player's id.

### 4.3 Activation (client)

- **Proximity PTT** (default key, rebindable): while held, `voice_capture` encodes + sends `kind=proximity`.
- **Squad PTT** (separate default key, rebindable): same, `kind=squad`.
- If both are held, squad takes precedence (avoids broadcasting squad comms to enemies by accident). No open-mic, ever (no hot-mic leak to enemies).

---

## 5. Client capture, jitter & playback

**Capture (`voice_capture.gd`).** An `AudioEffectCapture` on a mic bus yields PCM; while a PTT key is held, frames are resampled to 48 kHz mono 20 ms blocks and encoded by `OpusVoiceEncoder` → one `VOICE_FRAME` per block (~50/s). Silent when no key is held.

**Jitter buffer (`voice_jitter.gd`, pure).** Per speaker: a small ordered buffer (`JITTER_FRAMES` default 3 ≈ 60 ms) absorbs network jitter. Rules (deterministic, tested):
- Insert by `seq`; **drop** frames older than the last popped `seq` (late) and exact duplicates.
- Pop in `seq` order at playback cadence; a missing `seq` past the buffer depth is a **gap** (decoder may PLC/conceal or emit silence) — never stall waiting.
- Bounded size; overflow drops the oldest (a too-slow consumer never grows unbounded).

**Playback (`voice_playback.gd`).** One decoder + `AudioStreamGenerator` per active speaker:
- **Proximity** → an `AudioStreamPlayer3D` placed at the speaker's rendered position, routed through the **M7 audio engine** (`audio_mix` distance gain + occlusion cutoff; same attenuation/occlusion as gunfire) on the **Voice** bus. You locate talkers by ear; walls muffle them.
- **Squad** → a flat 2D player on the Voice bus (always intelligible, non-positional).
- **`MAX_PROXIMITY_SPEAKERS`** (default 4): only the nearest N proximity speakers get a live decoder; farther speakers are dropped client-side (the down-link analogue of the audio voice pool). Squad speakers (≤ squad size) are always decoded.
- **Mute set:** a client-side set of muted `speaker_id`s; muted frames are dropped before the jitter buffer.

**Voice bus.** A new `Voice` bus under `Master` (sibling to `SFX`/`UI`/`Listener`) gives users independent voice volume; declared with the rest of the bus layout (the M7 audio integration owns `default_bus_layout.tres` / `project.godot [audio]`).

---

## 6. Components & data flow

**Outbound (local player talks, proximity):**
1. PTT key down → `voice_ptt` → `voice_capture` encodes 20 ms blocks.
2. `voice_client` sends each `VOICE_FRAME(kind=proximity)` on the voice connection.

**Relay (voice thread, E-core):**
3. `voice_relay` receives the frame; resolves trusted `speaker_id` from the bound peer; `voice_packet.validate`.
4. `recipients = voice_routing.recipients_for(speaker_id, table.read(), kind)` (table is the latest published snapshot).
5. Overwrite `speaker_id`, `send()` the frame to each recipient's voice peer (unreliable). **No decode.**

**Inbound (remote speaker heard):**
6. `voice_client` receives `VOICE_FRAME`; if `speaker_id` muted → drop. Else route to that speaker's `voice_jitter`.
7. `voice_playback` pops in order, `OpusVoiceDecoder.decode` → `AudioStreamGenerator`; proximity placed in 3D via the audio engine, squad 2D. Listener pose fed each frame from the local camera/pawn.

Steps 3–4 and the jitter/PTT/codec logic are the **pure tested units**; steps 1/6–7's mic + `AudioStreamGenerator` + the socket/thread shell are owner-playtested.

---

## 7. Test plan

All pure logic is headless-unit-tested (`tests/*_test.gd`, `extends TestCase`, every test asserts; `godot --headless --path . -- --test --filter=voice`). Feel/intelligibility is the **owner's playtest** (AGENTS.md §10).

- **`voice_packet` (`tests/voice_packet_test.gd`):** round-trips `speaker_id/kind/seq/frame`; rejects bad `kind`, over-length frames, truncated buffers (drop + count, no crash).
- **`voice_routing` (`tests/voice_routing_test.gd`):** proximity returns exactly in-range, alive, voice-connected players, excludes self, sorted by distance, truncated to `MAX_VOICE_FANOUT`; squad returns same-team-same-squad only and **never an enemy**; players without a voice peer are never recipients.
- **`voice_routing_table` (`tests/voice_routing_table_test.gd`):** publish into the inactive buffer then flip leaves the prior snapshot intact for a concurrent reader; a reader always sees a fully-consistent table (no half-written entry); peer-bind handoff lands before the next publish.
- **`voice_jitter` (`tests/voice_jitter_test.gd`):** ordered pop for in-order insert; reorders a late-but-in-window frame; **drops** frames older than last-popped and duplicates; a gap past depth pops as a gap (no stall); overflow drops oldest; deterministic for a fixed insert stream.
- **`voice_ptt` (`tests/voice_ptt_test.gd`):** key-down opens the right channel, key-up closes; squad precedence when both held; no transmission when idle.
- **Session/anti-spoof (`tests/voice_session_test.gd`):** a valid token binds peer↔id; an invalid/expired/reused token is rejected; an ingress frame's client-supplied `speaker_id` cannot override the bound id; disconnect clears the binding.
- **Gate isolation proof (fleet/playtest, §8):** server `[perf]` shows the **P-core tick budget held** with heavy voice traffic injected; the `voice` relay-thread counter reports load off-tick.

The Opus FFI, mic capture, `AudioStreamGenerator`, and the live two-connection handshake are owner-playtested, not asserted headlessly.

---

## 8. Constants (initial values; playtest-tuned)

| Const | Value | Meaning |
|---|---|---|
| `VOICE_PORT` | 7778 | second UDP port for the voice host |
| `VOICE_FRAME_MS` | 20 | Opus frame duration (→ ~50 frames/s/speaker) |
| `VOICE_SAMPLE_RATE` | 48000 | Opus mono sample rate |
| `VOICE_BITRATE` | 24000 | target encoder bitrate (VBR) |
| `PROXIMITY_RANGE` | 50.0 m | max distance a proximity speaker is relayed/heard |
| `MAX_VOICE_FANOUT` | 12 | server cap on proximity recipients per frame |
| `MAX_PROXIMITY_SPEAKERS` | 4 | client cap on simultaneously-decoded proximity speakers (nearest-first) |
| `JITTER_FRAMES` | 3 | per-speaker jitter buffer depth (~60 ms) |
| `MAX_OPUS_FRAME_BYTES` | 256 | hard ingress bound on an encoded frame |
| `VOICE_TOKEN_TTL` | 10 s | voice-session token lifetime |
| `VOICE_THREAD_CPU` | E-cores (16–31) | relay-thread affinity (AGENTS.md §8) |

---

## 9. ADR-0006 — first GDExtension

The Opus codec requires a native library; pure GDScript cannot encode/decode Opus at frame cadence. This trips the GDExtension escalation lever ADR-0001 deliberately reserved ("escalate hot paths to GDExtension only if needed; record in a follow-up ADR"). **[ADR-0006](../adr/0006-gdextension-voice-codec.md)** records the decision: a `godot-rust/gdext` extension `native/voice_opus/`, the build/toolchain consequence (Rust + cargo now required to build the **client**; the dedicated server and bot driver do **not** link it — the server only relays opaque bytes and never decodes), and the rule that the extension stays a **leaf** (codec only; no gameplay rules, nothing from `shared/sim/`).

---

## 10. Open questions (owner)

1. **Echo cancellation / noise gate.** v1 relies on PTT + a simple capture noise gate. Full AEC is out of scope unless playtest demands it (would extend the GDExtension).
2. **Default PTT keys.** Proposed distinct proximity/squad keys (rebindable via the M7 settings menu); exact defaults are an owner call at wiring time.
3. **Voice in Docker fleet ports.** The 128-bot gate is bot-only (bots don't speak), so the voice port need not be exposed there; for the human playtest the voice port must be mapped/forwarded alongside the game port. Confirm at gate setup.
4. **`MAX_PROXIMITY_SPEAKERS` / `MAX_VOICE_FANOUT`.** Defaults chosen for a dense brawl; owner to confirm by ear/perf in the human playtest.
5. **gdext platform builds.** Which targets to ship the prebuilt `.so/.dll` for (Linux dev + the owner's Windows/desktop client) — resolved with ADR-0006 / the build runbook.

---

## 11. Explicit non-scope

- **No server-side mixing/decoding** — relay forwards opaque encoded frames only.
- **No voice on the game connection / P-core tick** — separate port + thread by design (§2).
- **No bot or spectator voice** — bots never speak (gate is human-validated); spectator/admin voice is deferred (M7.5 admin spectator pass, if ever).
- **No open-mic** — PTT only (no hot-mic leak to enemies).
- **No global/all-chat voice channel** — proximity + squad only.
- **No gameplay effect** — voice never feeds authority, lag-comp, hit-reg, or `shared/sim/`.
- **No voice recording/capture-to-disk, no music/ambience** — out of scope.

## Specs

- This spec is the brainstorm-of-record for the M6 voice system. Next: implementation plan in `docs/plans/` (`writing-plans`), executed with `test-driven-development` + `subagent-driven-development`. Companion decision: [ADR-0006](../adr/0006-gdextension-voice-codec.md). Reuses the M7-P2 [audio engine](audio.md) for positional proximity rendering.
