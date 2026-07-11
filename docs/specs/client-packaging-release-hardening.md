# Spec: Client Packaging & Release Hardening

**Status:** approved (design) · **Date:** 2026-07-11 · **Milestones:** pre-Steam-release hardening (first client export) → [M9](../milestones/M9-online-services.md) online/anti-cheat track. Decision record: [ADR-0010](../adr/0010-client-packaging-drm-hardening.md).

Defines how Blockfire is packaged, distributed, and hardened for a **Steam release**, covering the *client-side* concerns that [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md) (anti-cheat layers + matchmaking) does not: how Godot packs the client, reverse-engineering / asset extraction, anti-piracy, Steam-DLL emulators, transport encryption, network DoS surface, secret handling, and privacy obligations.

**Guiding principle (unchanged from AGENTS.md §7 / ADR-0004):** *the server is authoritative, the client sends intent, and the entire client `.pck` is assumed public.* Nothing here tries to make the client tamper-proof — that is impossible. Everything here protects the assets we can protect (the **official server population**, our **secrets**, and our **network surface**) and explicitly declines the battles we cannot win (client secrecy, offline piracy).

## Threat model (what we defend, what we don't)

| Threat | In scope? | Defense |
|---|---|---|
| Client tampering to forge damage/position/state | ✅ | Server authority + input validation (ADR-0004 L1–L2) — a hacked client only desyncs itself |
| Wallhack / ESP / radar from a decompiled client | ✅ | **Information minimization** — interest culling + relevance cap today, **LOS culling (L3)** before public launch (ADR-0004) |
| Aimbot / triggerbot | ✅ | Statistical detection (ADR-0004 L4, M9) |
| Non-owner joining **official** servers | ✅ | **Server-side** Steam session-ticket validation (`BeginAuthSession`) |
| Secrets leaking from the shipped client | ✅ | Export hygiene — no secrets in the `.pck`, ever |
| Wire sniffing / MITM on the internet | ✅ (pre-launch) | **DTLS** on official servers |
| Malformed-packet crash / connection-flood DoS | ✅ | Bounded wire reads + per-peer rate-limit/caps |
| Reverse-engineering client code | ❌ (unpreventable) | Assumed public; design grants no advantage from it |
| Extracting client models/textures/data | ❌ (unpreventable) | Assumed public; only original art is at risk and we accept it |
| Non-owner playing **offline / LAN / on cracked servers** | ❌ (non-goal) | Not defended — pirates play among themselves, walled off from official play |

## A. How Godot packs the client (reference)

- `godot --export-release "Windows Desktop"` → `blockfire.exe` + `blockfire.pck` (or `.pck` embedded in the `.exe`). The `.pck` is a resource archive of everything under `res://`.
- **GDScript** ships as tokenized bytecode, **not** source — but `gdsdecomp` reconstructs near-original GDScript (logic intact; comments/local names lost) from a 4.x `.pck`. Treat all client GDScript as readable.
- **Resources** (`.tres`/`.res`/`.json`, meshes, textures, audio) unpack cleanly with the same tools. Weapon stats, ballistics tables, damage numbers, and map data are all extractable and human-readable.
- **PCK encryption** (AES-256 via custom-compiled export templates) raises the extraction bar but not the RE bar (the key ships in the binary). Not used as a boundary (ADR-0010 §1); may be enabled later as a casual speed-bump only.

## B. Export hygiene (hard requirement — enforced at the first export)

The single-project, role-at-runtime layout ([ADR-0002](../adr/0002-project-structure.md)) means the default export would ship server-only code and any secrets to players. The **client** export MUST NOT contain:

- server-only logic that is not needed for client prediction (dedicated-server orchestration, match-report signing, admin/ops paths);
- `bots/` AI internals not needed by the client;
- **any secret**: Steam Web API **publisher key**, match-report **signing keys**, DB credentials, or hard-coded backend/admin URLs and ports;
- backend/infrastructure config files.

Rules:

- **Two export targets:** a **player client** and a **dedicated server**, exported and shipped separately. The dedicated server is not distributed to players.
- **Explicit export filters:** use `export_presets.cfg` include/exclude filters so the client `.pck` carries only what the client needs. Prefer an allowlist mindset for `server/`-adjacent paths (default-exclude, include the few shared entry points the client legitimately runs).
- **`shared/` is client-safe by construction** — it holds only deterministic rules that already run on the client (AGENTS.md §7). Keep it that way: no secret or server-only endpoint ever lands in `shared/`.
- **GodotSteam stays at the client/server edge** (ADR-0004) — never in `shared/`, and the client build never embeds the publisher key (that key lives only in the backend `steam-web-worker`).
- **CI check:** an automated post-export scan asserts the client `.pck` contains no known-secret markers and none of the excluded server-only paths. A hit fails the release build.

## C. Anti-piracy & the Steam-DLL emulator question

- **Ownership is validated server-side, never client-side** (ADR-0010 §2). Flow (ADR-0004 "Steam integration"): client `GetAuthSessionTicket` → dedicated server `BeginAuthSession` confirms with Valve that the account owns the app and is not VAC/game-banned → relayed to the backend auth-gateway for a SteamID-keyed session.
- **What an emulator (Goldberg etc.) can do:** replace `steam_api64.dll`, fake a SteamID, spoof local ownership, and let a non-owner launch and play **offline / LAN / on cracked servers**. This is unpreventable and out of scope.
- **What it cannot do:** forge a session ticket that Valve's `BeginAuthSession` accepts. So an emulated client **cannot join an official/authenticated server** — the server rejects the invalid ticket. Our ranked/official population stays clean.
- **Community servers** (BattleBit-style) may choose not to validate tickets; that is allowed, and their matches already do not affect rating (ADR-0004 trust model). Only the **official** pool must always validate.
- **Steam DRM wrapper:** not counted as protection (trivially stripped); may be toggled on as a zero-effort deterrent.

## D. Transport encryption (DTLS)

- **Today:** low-level ENet over plaintext UDP (`shared/net/net_host.gd`). Fine for LAN/dev.
- **Before public internet launch:** enable **DTLS** on official servers (Godot ENet supports it) so the wire protocol is not trivially sniffable/MITM-able and packet inspection can't shortcut wire-format RE.
- **Constraints:** DTLS adds per-packet CPU + handshake cost; it must be profiled against the tick/bandwidth budget at 128 players via `[perf]` telemetry before it gates. LAN/dev builds may keep plaintext for iteration speed (config flag, default-on for official).
- **Not a substitute** for server authority or field validation — encryption stops sniffing/MITM, not a hacked first-party client.

## E. Wire hardening & network DoS surface

A public 128-slot UDP server is an internet-facing attack surface. Keep and extend the existing discipline:

- **Bound every field read off the wire**, server-side, before use — already done (`input_command.gd` "never trust the frame count", `gadget_list.gd` `MAX=96`, `support_links.gd` `MAX=64`, `build.gd` range-rejects). Every new wire message added to the [wire-protocol registry](wire-protocol-registry.md) inherits this rule.
- **`Protocol.VERSION` handshake** rejects mismatched builds — keep bumping it on any wire change; it doubles as a stale/cracked-client gate after each patch.
- **Add before public launch:** per-peer **connection rate-limiting** and a **connection cap**, plus sane per-peer packet-rate/size limits, so connection floods and malformed-packet fuzzing can't exhaust the server. Reuse the ENet peer stats already read for telemetry.
- **Input validation (ADR-0004 L2)** remains the clamp-don't-reject boundary (`shared/sim/input_validate.gd`) for gameplay-affecting inputs.

## F. Secrets inventory (must live server/backend-side only)

| Secret | Lives in | Never in |
|---|---|---|
| Steam Web API **publisher key** | backend `steam-web-worker` | client, server binary, `shared/`, repo |
| Match-report **signing key** | official dedicated server / backend | client `.pck` |
| DB credentials, backend URLs | backend services / server env | client `.pck` |
| Steam App ID (public) | client (public value — fine) | — |

All secrets are provided at runtime via env/secret store, never committed and never bundled in an export.

## G. Privacy & data retention (online services)

SteamID-keyed persistence (M9/M20) makes us a data controller:

- **Privacy policy** published before online services launch.
- **Retention:** reaffirm the **90-day event retention** already pinned for the stats backend; enforce it in-schema (TTL / partition drop), not by manual cleanup.
- **Deletion path** for player data requests.
- Soft Steam signals (owned-games/level/age) stay best-effort and never hard-gate private-profile players (ADR-0004).

## H. Platform notes

- **Steam Deck / Linux:** the server-side + VAC posture (ADR-0004) is Deck-friendly; kernel AC would hurt it (cf. BattleBit's EAC→FACEIT move). Keeping anti-cheat server-side preserves the Deck/Linux audience.
- **Steam Direct cost:** $100/app (recoupable), SDK/auth/VAC free (ADR-0004).

## Pre-public-launch checklist (release gate)

- [ ] `export_presets.cfg` with enforced client/server split + secret exclusion; separate dedicated-server export.
- [ ] CI post-export scan: no secrets / no excluded server-only paths in the client `.pck`.
- [ ] Server-side Steam session-ticket validation live on the official pool; no client-side ownership gate anywhere.
- [ ] DTLS enabled + perf-checked at 128 on official servers.
- [ ] Per-peer connection rate-limit + connection cap on the dedicated server.
- [ ] LOS culling (ADR-0004 Layer 3) shipped.
- [ ] Privacy policy + enforced 90-day retention + deletion path for the backend.

## Test plan

- **Export hygiene:** automated test unpacks a fresh client export and asserts (a) no file under the excluded server-only paths is present, (b) no known-secret marker/string is present, (c) the dedicated-server export is a separate artifact. Release build fails on any violation.
- **Ownership validation:** integration test that a connection presenting an invalid/emulated session ticket is refused by the official server, and a valid ticket is accepted; assert no client-side code path grants access without server confirmation.
- **DTLS:** connect over DTLS end-to-end; bench the handshake + per-packet cost stays within the 128-player tick/bandwidth budget; assert plaintext is refused on an official-configured server.
- **Wire hardening / DoS:** fuzz malformed/oversized/out-of-range packets → assert reject + telemetry counter, no crash; simulate connection flood → assert rate-limit/cap engages and legitimate peers still connect; assert `Protocol.VERSION` mismatch is rejected.
- **Retention:** insert events older than 90 days → assert they are dropped by the retention mechanism, not retained.

## Out of scope (this spec)

- Anti-cheat **layers** and **matchmaking** internals — owned by [ADR-0004](../adr/0004-anti-cheat-and-skill-matchmaking.md) / [anti-cheat-matchmaking spec](anti-cheat-matchmaking.md). This spec references them but does not redefine them.
- Kernel anti-cheat (EAC/BattlEye) — deferred (ADR-0004); a separate future ADR if escalated.
- Concrete `export_presets.cfg` filter lists — produced when the first export is authored, against this spec's rules.

## References

- Godot RE Tools (`gdsdecomp`): <https://github.com/bruvzg/gdsdecomp>
- Godot export / PCK encryption: <https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html>, <https://docs.godotengine.org/en/stable/contributing/development/compiling/compiling_with_script_encryption_key.html>
- Godot ENet DTLS: <https://docs.godotengine.org/en/stable/classes/class_enetconnection.html>
- Steamworks auth (`GetAuthSessionTicket` / `BeginAuthSession`): <https://partner.steamgames.com/doc/features/auth>
- GodotSteam: <https://godotsteam.com>
