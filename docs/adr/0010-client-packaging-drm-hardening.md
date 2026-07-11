# ADR-0010: Client packaging, DRM & release hardening

- **Status:** Accepted
- **Date:** 2026-07-11
- **Context milestone:** pre-Steam-release hardening (first client export) → [M9](../milestones/M9-online-services.md) online/anti-cheat track

## Context

Blockfire began as a LAN-only game and is now a plausible **Steam release** candidate. That raises a set of *client-side* release concerns distinct from the anti-cheat/matchmaking questions already settled in [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md): how Godot packs the Windows client, whether the game can be reverse-engineered or its assets extracted, how (and whether) piracy can be resisted, and what a Steam-DLL emulator can and cannot do. We have **never exported** yet (no `export_presets.cfg`), so these decisions can be made correctly the first time rather than retrofitted.

Key technical facts that constrain every option below:

- **A Godot export `.pck` is fully extractable.** It bundles everything under `res://` — scenes, models, textures, audio, data files (`.tres`/`.json`), and GDScript. GDScript ships as bytecode, not source, but off-the-shelf tools ([Godot RE Tools / `gdsdecomp`](https://github.com/bruvzg/gdsdecomp)) reconstruct near-original GDScript and unpack all resources from a Godot 4.x `.pck` with no skill required.
- **PCK encryption is a speed-bump, not a boundary.** Godot supports AES-256 `.pck` encryption via custom-compiled export templates, but the key ships inside the executable; a determined attacker extracts it and decrypts. It stops casual drag-and-drop extraction only, at the cost of maintaining custom export templates and key management.
- **The client cannot be made tamper-proof.** This is why the project is server-authoritative (AGENTS.md §7): a modified/decompiled client can only desync itself. That property is what makes the client-side threats here *manageable* rather than *fatal*.
- **A Steam-DLL emulator (e.g. Goldberg) defeats any client-side ownership check** by faking a SteamID and spoofing ownership. It **cannot** forge a session ticket that Valve's `BeginAuthSession` will accept, so it cannot get onto a server that validates ownership server-side.
- **We are single-project, role-selected-at-runtime** ([ADR-0002](0002-project-structure.md)). A naive client export would bundle `server/`, `bots/`, and any backend endpoints/secrets into the shipped `.pck`.
- **Transport is currently low-level ENet (`shared/net/net_host.gd`), unencrypted UDP.** Godot's ENet supports DTLS.

## Decision

1. **Treat the entire client `.pck` as public.** Do not rely on PCK encryption or obfuscation as a security or IP-protection boundary. Design every system so that full knowledge of client code and data grants no advantage — which the server-authoritative model already provides. AES PCK encryption **MAY** be enabled later purely as a casual-extraction speed-bump; it is never counted as protection and never gates a security decision.

2. **Anti-piracy for online play is server-side Steam ownership validation only** (per ADR-0004's Steam integration: client `GetAuthSessionTicket` → dedicated server `BeginAuthSession` against Valve). **Ownership/online-access MUST NEVER be gated by a client-side check.** Offline / LAN / cracked-server play by non-owners is **unpreventable and explicitly out of scope** — we do not spend effort on it. What we protect is the **official/authenticated server population**, which a ticket emulator cannot join.

3. **Do not treat the Steam DRM wrapper as protection.** It is trivially stripped. It may be enabled as a zero-effort deterrent but earns no place in any threat model.

4. **Export hygiene is a hard requirement, enforced from the first export.** The client export **MUST** exclude server-only and backend code paths, dedicated-server logic, and every secret. The dedicated server is exported/shipped separately from the player client. No secret (Steam Web API publisher key, match-report signing keys, DB credentials, backend URLs) ever appears in the client `.pck` — string-dumping it is trivial. Enforced via export filters; see the spec.

5. **Encrypt official-server transport (DTLS) before public internet launch.** LAN and dev may remain plaintext ENet; official internet servers enable DTLS so the wire protocol is not trivially sniffable/MITM-able. This is a pre-launch gate item, not a day-one-of-networking change.

6. **The network-facing server is a DoS/fuzzing surface and is hardened as one.** Every field read off the wire is bounded and validated server-side (already the discipline — `input_command.gd`, `gadget_list.gd`/`support_links.gd` caps, the `Protocol.VERSION` handshake). Add per-peer connection rate-limiting and connection caps before public launch. The `Protocol.VERSION` gate doubles as a stale/cracked-client gate after each patch.

7. **SteamID-keyed persistence triggers data-controller obligations.** Once the M9/M20 backend stores per-SteamID stats, we owe a privacy policy, a bounded retention window (**reaffirm the 90-day event retention** already pinned for the stats backend), and a deletion path. Bake retention into the schema, not on as an afterthought.

8. **Line-of-sight culling (Layer 3, ADR-0004) is the durable anti-wallhack** and its priority is elevated for public release. Because the client is fully RE-able, the only real defense against wallhack/ESP is to not replicate what a player cannot plausibly see; hiding the client does nothing.

## Rationale

- **Matches the project's existing posture.** Server authority (AGENTS.md §7) already makes client tampering self-defeating; these decisions extend the same "trust nothing on the client" principle to packaging, ownership, and transport instead of fighting the un-winnable battle of client secrecy.
- **Spends effort only where it pays.** Client obfuscation/DRM is high-effort, low-value, and defeated as a matter of routine; server-side ticket validation is low-effort and actually protects the population that matters. We invest in the latter and explicitly decline the former.
- **Correct-by-construction export.** Deciding export hygiene before the first export costs minutes; retrofitting it after secrets or server logic have shipped in a public `.pck` is a security incident.
- **Consistent with ADR-0004 and the project's YAGNI/gate posture.** Kernel AC stays deferred; DTLS and DoS hardening are scoped to *before public launch*, not imposed on the LAN game today.

## Consequences

- The first `export_presets.cfg` must carry an enforced client/server split (include/exclude filters) and a secret-exclusion rule; the dedicated server ships as a separate export. This is new build/release work owned by the release-hardening track.
- Enabling DTLS on official servers is added to the pre-public-launch checklist; it interacts with the `net_host.gd` transport layer and must be perf-checked against the tick/bandwidth budget at 128.
- Per-peer rate-limiting/connection caps are added to the dedicated server before public launch (network DoS surface).
- The backend (M9/M20) carries privacy-policy + retention + deletion obligations as launch blockers for online services.
- We accept that pirates can always play offline/LAN/cracked-server among themselves; this is a deliberate non-goal, not a gap.
- If PCK encryption is ever enabled, it obligates maintaining custom-compiled export templates and a key — accepted only if/when casual extraction becomes a demonstrated problem.
- Supersede with a new ADR if we ever adopt client-side DRM/kernel AC as a real boundary (today: explicitly not).

## Links

- Spec: [Client Packaging & Release Hardening](../specs/client-packaging-release-hardening.md)
- Related: [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md) (anti-cheat layers, Steam auth, LOS culling — this ADR complements, does not supersede), [ADR-0002](0002-project-structure.md) (single-project role-at-runtime — the reason export filtering is required), [ADR-0005](0005-client-renderer.md) (rendered client)
- Milestone: [M9 — Online Services](../milestones/M9-online-services.md)
