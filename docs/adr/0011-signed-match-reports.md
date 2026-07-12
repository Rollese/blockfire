# ADR-0011: Signed match reports (HMAC-SHA256, per-server keys)

- **Status:** Accepted
- **Date:** 2026-07-12
- **Context milestone:** M9-P1 (Online Services, phase 1)
- **Refines:** [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md) decision #5 ("only
  official, authenticated servers report rating-affecting results — signed match reports").
  ADR-0004 ratified *that* reports are signed; this ADR settles *how*.

## Context

M20 stood up the stats datastore + ingest API ([design](../superpowers/specs/2026-07-11-stats-analytics-backend-design.md),
§9 lists signed reports as M9-deferred). Its ingest is gated by a **single shared bearer
token**: any holder can POST a match report or event batch and the backend trusts it
implicitly. That is acceptable for balancing analytics but not for the rating (M9-P2) and
Layer-4 statistical detection (M9-P3) that will consume this data — those must trust only
results a **specific, authenticated official server** actually produced, per ADR-0004 and
the [anti-cheat-matchmaking spec](../specs/anti-cheat-matchmaking.md) trust model.

Forces:
- The **game server is our own infrastructure**, not the untrusted client (the client's
  Steam ticket is validated *by the server*, which is what POSTs). A secret shared between
  two systems we operate is a reasonable trust anchor.
- Community/BattleBit-style untrusted hosts are a *future* concern (M9-P4+); no untrusted
  party submits rating-affecting reports in P1.
- Both signer (Godot/GDScript) and verifier (Python) must produce byte-identical results
  with no new heavyweight dependency. Godot exposes `HMACContext` (HMAC-SHA256) natively but
  **no Ed25519**, and RSA in GDScript means PEM/key-format handling.
- The change must be backward compatible with M20 dev servers already POSTing unsigned.

## Decision

1. **HMAC-SHA256 with per-server shared secrets.** Each official server holds a
   `key_id` + secret; the backend holds a `key_id → secret` map. Native on both sides,
   no new dependency, keeps the phase small.
2. **Sign an envelope over the raw request body bytes**, carried in `X-BF-Key-Id` /
   `X-BF-Timestamp` / `X-BF-Signature` headers — signing string
   `key_id + "\n" + timestamp + "\n" + raw_body`. Signing the transmitted bytes (not a
   re-canonicalized JSON) avoids cross-language JSON-canonicalization drift and leaves the
   M20 body schema untouched.
3. **The existing bearer token stays** as the coarse "who may POST at all" gate; signing
   layers on top to add per-server identity, payload integrity, and trust attribution.
4. **Durable `trusted` flag on `matches`.** A validly-signed `/ingest/match` sets
   `trusted=true`; downstream rating/Layer-4 filter on it.
5. **Backward-compatible trust tiers.** Default `REQUIRE_SIGNED_INGEST=False`: unsigned
   requests still ingest as `trusted=false` (analytics only); a *present-but-invalid*
   signature is rejected 401 (attack signal, never downgraded). Prod sets
   `REQUIRE_SIGNED_INGEST=True` to 401 everything unsigned.
6. **No nonce replay store in P1.** Ingest is already idempotent (`(match_id, batch_seq)`
   / `match_id` upsert) and the signature binds the body, so replays inject nothing new; a
   bounded timestamp skew (`INGEST_MAX_SKEW_S`, default 300 s) caps the acceptance window.

## Alternatives considered

- **Asymmetric signatures (RSA via Godot `Crypto.sign`, or Ed25519).** Backend never holds
  signing capability (survives a backend compromise) and models untrusted community hosts
  more cleanly. Rejected for P1: heavier (PEM/keygen in GDScript; Godot has no Ed25519) for
  a trust boundary that is, in P1, between two systems we both operate. Revisit via a
  superseding ADR if untrusted community servers ever submit rating-affecting reports.
- **Keep the bare bearer token.** Rejected: no per-server identity/revocation, no payload
  binding, no trust attribution — exactly what rating/Layer-4 need.
- **Canonical-JSON signing.** Rejected: JSON key ordering / float formatting / whitespace
  differ across Godot and Python; signing raw transmitted bytes sidesteps it entirely.

## Consequences

- The backend gains a `key_id → secret` map (`INGEST_SIGNING_KEYS` env) — a shared secret,
  so a leak from **either** side allows forgery until rotated. Accepted because both ends are
  our infrastructure; asymmetric is the escalation if that stops holding.
- `matches.trusted` becomes the contract every later M9 phase filters on. Introduced via an
  idempotent `ADD COLUMN IF NOT EXISTS` guard (Alembic still not adopted for one boolean).
- Key rotation is manual (edit the env map, restart) in P1; automated rotation/secret-manager
  is deferred.
- Supersede with a new ADR if kernel-AC-grade or community-server trust requires asymmetric
  keys, per-report nonces, or an HSM.

## Links
- Spec: [M9-P1 — Signed match reports design](../superpowers/specs/2026-07-12-m9-p1-signed-match-reports-design.md)
- Refines: [ADR-0004](0004-anti-cheat-and-skill-matchmaking.md) · Trust model: [anti-cheat-matchmaking](../specs/anti-cheat-matchmaking.md)
- Milestone: [M9 — Online Services](../milestones/M9-online-services.md)
